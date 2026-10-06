require "sqlite3"
require "digest"
require "fileutils"

class LanguageStatistics
  MAX_PREFIX = 13
  BLOCK_SIZE = 256 * 1024
  ALPHABET = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя., !?".freeze

  CODES = ALPHABET.each_char.with_index.to_h do |char, index|
    [char, (index + 1).chr(Encoding::BINARY)]
  end.freeze

  def initialize(database)
    @database = database
    @db = SQLite3::Database.new(database)
    @db.busy_timeout = 5000

    old_table = @db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'frequencies'"
    )

    raise "Это старая база. Укажи другое имя для новой базы." if old_table

    @db.execute("PRAGMA journal_mode = WAL")
    @db.execute("PRAGMA synchronous = FULL")
    @db.execute("PRAGMA cache_size = -65536")

    @db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS grams (
    gram BLOB PRIMARY KEY,
    amount INTEGER NOT NULL CHECK (amount > 0)
    ) WITHOUT ROWID
    SQL

    @db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS symbols (
    code INTEGER PRIMARY KEY,
    amount INTEGER NOT NULL CHECK (amount > 0)
    )
    SQL

    @db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS progress (
    path TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    position INTEGER NOT NULL,
    history BLOB NOT NULL
    )
    SQL
  end

  def build(folder)
    paths = Dir.glob(File.join(folder, "*.txt")).sort
    raise "В папке нет файлов TXT" if paths.empty?

    File.open("#{@database}.lock", "a") do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise "Эта база уже обрабатывается другим процессом"
      end

      paths.each do |path|
        process_file(File.expand_path(path))
      end
    end

    puts "Обработка завершена."
  end

  def print_probabilities(prefix = "")
    prefix = prefix.downcase

    unless prefix.length <= MAX_PREFIX &&
           prefix.each_char.all? { |char| CODES.key?(char) }
      raise "Префикс должен содержать от 0 до 13 допустимых символов"
    end

    counts = get_counts(prefix)
    total = counts.values.sum

    if total.zero?
      puts "Для этого префикса нет наблюдаемых продолжений."
      return
    end

    puts prefix.empty? ? "Общие вероятности символов" : "Префикс: #{prefix.inspect}"
    puts "Всего наблюдений: #{total}"
    puts "Символ\tКоличество\tВероятность"

    ALPHABET.each_char.with_index do |char, index|
      amount = counts.fetch(index + 1, 0)
      probability = amount.fdiv(total)
      label = char == " " ? "[пробел]" : char

      puts "#{label}\t#{amount}\t#{format('%.12f', probability)}"
    end
  end

  def close
    @db.close
  end

  def process_file(path)
    fingerprint = Digest::SHA256.file(path).hexdigest()

    saved = @db.get_first_row(
      "SELECT fingerprint, position, history FROM progress WHERE path = ?",
      [path]
    )

    if saved && saved[0] != fingerprint
      raise "Файл изменился после начала подсчёта: #{path}. Нужна новая база."
    end

    position = saved ? saved[1] : 0
    history = saved ? saved[2].b : "".b
    size = File.size(path)

    puts "Файл: #{File.basename(path)}"

    if position == size
      puts "Уже обработан."
      return
    end

    last_message = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    File.open(path, "rb") do |file|
      file.seek(position)

      while (text = read_block(file))
        frequencies = Hash.new(0)
        symbols = Hash.new(0)

        history = count_block(text, history, frequencies, symbols)

        save_block(
          path,
          fingerprint,
          file.pos,
          history,
          frequencies,
          symbols
        )

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if now - last_message >= 5 || file.pos == size
          percent = file.pos.fdiv(size) * 100

          puts "#{format('%.2f', percent)}% — " \
               "#{file.pos} / #{size} байт"

          last_message = now
        end
      end
    end
  end

  def read_block(file)
    text = file.read(BLOCK_SIZE)
    return nil unless text

    text.force_encoding(Encoding::UTF_8)

    3.times do
      break if text.valid_encoding?

      byte = file.read(1)
      break unless byte

      text << byte.force_encoding(Encoding::UTF_8)
    end

    raise "Файл содержит некорректный UTF-8" unless text.valid_encoding?

    text
  end

  def count_block(text, history, frequencies, symbols)
    text = text.downcase.gsub(/[^а-яё., !?]/, " ").squeeze(" ")
    space = CODES.fetch(" ").getbyte(0)

    text.each_char do |char|
      code = CODES.fetch(char)
      number = code.getbyte(0)

      if number == space && (history.empty? || history.getbyte(0) == space)
        next
      end

      gram = code + history

      frequencies[gram] += 1
      symbols[number] += 1

      history = gram.byteslice(0, MAX_PREFIX)
    end

    history
  end

  def save_block(path, fingerprint, position, history, frequencies, symbols)
    @db.transaction do
    @db.prepare(<<~SQL) do |statement|
    INSERT INTO grams (gram, amount)
    VALUES (?, ?)
    ON CONFLICT (gram)
    DO UPDATE SET amount = grams.amount + excluded.amount
    SQL
    frequencies.sort_by { |gram, _| gram }.each do |gram, amount|
      statement.execute!(SQLite3::Blob.new(gram), amount)
    end
    end

    @db.prepare(<<~SQL) do |statement|
    INSERT INTO symbols (code, amount)
    VALUES (?, ?)
    ON CONFLICT (code)
    DO UPDATE SET amount = symbols.amount + excluded.amount
    SQL
    symbols.each do |code, amount|
      statement.execute!(code, amount)
    end
    end

    @db.execute(
    <<~SQL,
    INSERT INTO progress (path, fingerprint, position, history)
    VALUES (?, ?, ?, ?)
    ON CONFLICT (path)
    DO UPDATE SET
    position = excluded.position,
    history = excluded.history
    SQL
    [path, fingerprint, position, SQLite3::Blob.new(history)]
    )
    end
  end

  def get_counts(prefix)
    if prefix.empty?
      return @db.execute("SELECT code, amount FROM symbols").to_h
    end

    encoded = prefix.reverse.each_char.map { |char| CODES.fetch(char) }.join.b
    counts = {}

    @db.transaction do
      CODES.each_value do |code|
        lower = code + encoded
        upper = lower.dup
        last = upper.bytesize - 1
        upper.setbyte(last, upper.getbyte(last) + 1)

        counts[code.getbyte(0)] = @db.get_first_value(
          "SELECT COALESCE(SUM(amount), 0) FROM grams WHERE gram >= ? AND gram < ?",
          [SQLite3::Blob.new(lower), SQLite3::Blob.new(upper)]
        )
      end
    end

    counts
  end

  private :process_file, :read_block, :count_block, :save_block, :get_counts
end

statistics = nil

begin
  command = ARGV.shift

  case command
  when "build"
    folder = ARGV.shift
    database = ARGV.shift || "data/compact.sqlite3"

    raise "Укажи папку с текстами" unless folder
    raise "Папка не существует: #{folder}" unless Dir.exist?(folder)

    FileUtils.mkdir_p(File.dirname(database))

    statistics = LanguageStatistics.new(database)
    statistics.build(folder)
  when "query"
    database = ARGV.shift
    prefix = ARGV.shift || ""

    unless database && File.file?(database)
      raise "Укажи существующий файл базы данных"
    end

    statistics = LanguageStatistics.new(database)
    statistics.print_probabilities(prefix)
  else
    puts "Подсчёт: ruby stat.rb build ПАПКА [БАЗА]"
    puts 'Вероятности: ruby stat.rb query БАЗА ["ПРЕФИКС"]'
  end
rescue Interrupt
  warn "\nОстановлено. Повтори команду для продолжения."
  exit 130
rescue StandardError => error
  warn "Ошибка: #{error.message}"
  exit 1
ensure
  statistics&.close
end
