require "sqlite3"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class StatisticsTest
    ALPHABET = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя., !?".freeze
    BLOCK_SIZE = 256 * 1024

    def initialize
        @script = File.expand_path("stat.rb", __dir__)
        @checks = 0
    end

    def run
        raise "Не найден stat.rb" unless File.file?(@script)

        Dir.mktmpdir("statistics_test_") do |root|
            @root = root

            test_small
            test_normalization
            test_files
            test_all_lengths
            test_empty
            test_blocks_and_recovery
            test_changed_file
        end

        puts "\nВсе проверки пройдены: #{@checks}"
    end

    def assert(condition, message)
        raise message unless condition

        @checks += 1
    end

    def command(*arguments, hook: nil)
        parts = [RbConfig.ruby]
        parts += ["-r", hook] if hook
        parts += [@script, *arguments]

        Open3.capture3(*parts)
    end

    def successful(*arguments)
        output, error, status = command(*arguments)

        unless status.success?
            raise "Команда завершилась ошибкой:\n#{output}\n#{error}"
        end

        output
    end

    def prepare(name, files)
        folder = File.join(@root, name)
        FileUtils.mkdir_p(folder)

        files.each do |filename, text|
            File.binwrite(File.join(folder, filename), text)
        end

        [folder, File.join(@root, "#{name}.sqlite3")]
    end

    def reference(texts)
        result = Hash.new(0)

        texts.each do |text|
            chars = text.chars

            chars.each_index do |index|
                0.upto([index, 13].min) do |length|
                    prefix = chars[index - length, length].join
                    result[[prefix, chars[index]]] += 1
                end
            end
        end

        result
    end

    def expanded_counts(database)
        result = Hash.new(0)
        alphabet = ALPHABET.chars
        db = SQLite3::Database.new(database)

        begin
            db.execute("SELECT gram, amount FROM grams") do |gram, amount|
                unless gram.bytesize.between?(1, 14)
                    raise "Некорректная длина окна: #{gram.bytesize}"
                end

                unless gram.bytes.all? { |code| code.between?(1, 38) }
                    raise "В базе встретился недопустимый код символа"
                end

                sequence = gram.bytes.reverse.map { |code| alphabet[code - 1] }
                next_char = sequence.last

                0.upto(sequence.length - 1) do |length|
                    start = sequence.length - length - 1
                    prefix = sequence[start, length].join

                    result[[prefix, next_char]] += amount
                end
            end
        ensure
            db.close
        end

        result
    end

    def verify_database(database, expected)
        actual = expanded_counts(database)

        mismatch = (expected.keys | actual.keys).find do |key|
            expected[key] != actual[key]
        end

        assert(
            mismatch.nil?,
            "Частоты не совпали для #{mismatch.inspect}: " \
        "ожидалось #{expected[mismatch]}, получено #{actual[mismatch]}"
        )

        db = SQLite3::Database.new(database)

        begin
            symbols = db.execute("SELECT code, amount FROM symbols").to_h
        ensure
            db.close
        end

        ALPHABET.each_char.with_index do |char, index|
            assert(
                symbols.fetch(index + 1, 0) == expected[["", char]],
                "Ошибка общей частоты символа #{char.inspect}"
            )
        end
    end

    def verify_query(database, prefix, expected)
        output = successful("query", database, prefix)
        rows = {}

        output.each_line do |line|
            parts = line.strip.split("\t")
            next unless parts.length == 3
            next unless parts[1].match?(/\A\d+\z/)

            char = parts[0] == "[пробел]" ? " " : parts[0]
            rows[char] = [Integer(parts[1]), Float(parts[2])]
        end

        total = ALPHABET.each_char.sum do |char|
            expected[[prefix, char]]
        end

        if total.zero?
            assert(
                output.include?("нет наблюдаемых продолжений"),
                "Не обработан отсутствующий префикс #{prefix.inspect}"
            )
            return
        end

        assert(rows.length == 38, "Выведены не все 38 символов")

        ALPHABET.each_char do |char|
            amount, probability = rows.fetch(char)
            wanted = expected[[prefix, char]]

            assert(
                amount == wanted,
                "Ошибка query для #{[prefix, char].inspect}"
            )

            assert(
                (probability - wanted.fdiv(total)).abs <= 1e-10,
                "Неверная вероятность для #{[prefix, char].inspect}"
            )
        end

        sum = rows.values.sum { |_, probability| probability }

        assert(
            (sum - 1.0).abs <= 1e-9,
            "Сумма вероятностей для #{prefix.inspect} не равна 1"
        )

        assert(
            output.include?("Всего наблюдений: #{total}"),
            "Неверный знаменатель для #{prefix.inspect}"
        )
    end

    def snapshot(database)
        db = SQLite3::Database.new(database)

        begin
            {
                grams: db.execute("SELECT gram, amount FROM grams ORDER BY gram"),
                symbols: db.execute("SELECT code, amount FROM symbols ORDER BY code"),
                progress: db.execute(
                                     "SELECT path, fingerprint, position, history FROM progress ORDER BY path"
                                    )
            }
        ensure
            db.close
        end
    end

    def test_small
        folder, database = prepare("small", {"sample.txt" => "абаба"})
        expected = reference(["абаба"])

        successful("build", folder, database)
        verify_database(database, expected)

        ["", "а", "б", "аб", "аба", "абаб", "абаба", "я"].each do |prefix|
            verify_query(database, prefix, expected)
        end

        before = snapshot(database)
        successful("build", folder, database)

        assert(
            snapshot(database) == before,
            "Повторный запуск изменил уже посчитанные данные"
        )

        puts "OK: абаба, конец текста, отсутствующие префиксы, повторный запуск"
    end

    def test_normalization
        raw = " \n\tЁЖ,  ёж!\r\nА-Б\t123XYZ🙂В?...\n"
        clean = "ёж, ёж! а б в?... "

        folder, database = prepare("normalization", {"sample.txt" => raw})
        expected = reference([clean])

        successful("build", folder, database)
        verify_database(database, expected)

        ["", "ё", "Ё", "ж", " ", "а ", "?"].each do |prefix|
            verify_query(database, prefix, expected_for_query(expected, prefix))
        end

        puts "OK: регистр, ё, пунктуация, пробелы, цифры, латиница, emoji"
    end

    def expected_for_query(expected, prefix)
        return expected if prefix == prefix.downcase

        result = expected.dup

        ALPHABET.each_char do |char|
            result[[prefix, char]] = expected[[prefix.downcase, char]]
        end

        result
    end

    def test_files
        folder, database = prepare(
            "separate_files",
            {"first.txt" => "аб", "second.txt" => "вг"}
        )

        expected = reference(["аб", "вг"])

        successful("build", folder, database)
        verify_database(database, expected)
        verify_query(database, "б", expected)
        verify_query(database, "в", expected)

        puts "OK: между файлами нет искусственных переходов"
    end

    def test_all_lengths
        text = ALPHABET + ALPHABET.reverse + "абвгдеёжзийклмн"
        folder, database = prepare("all_lengths", {"sample.txt" => text})
        expected = reference([text])

        successful("build", folder, database)
        verify_database(database, expected)

        0.upto(13) do |length|
            verify_query(database, text[0, length], expected)
        end

        _, _, status = command("query", database, "а" * 14)
        assert(!status.success?, "Принят префикс длиной 14")

        _, _, status = command("query", database, "abc")
        assert(!status.success?, "Принят префикс с латиницей")

        puts "OK: все 38 символов, длины 0–13, недопустимые запросы"
    end

    def test_empty
        folder, database = prepare(
            "empty",
            {"empty.txt" => "", "noise.txt" => "123ABC🙂\n\t"}
        )

        expected = reference(["", ""])

        successful("build", folder, database)
        verify_database(database, expected)
        verify_query(database, "", expected)

        puts "OK: пустой текст и текст без допустимых символов"
    end

    def test_blocks_and_recovery
        beginning = "а" * ((BLOCK_SIZE - 1) / 2) + "!"
        raw = beginning + "Ё \n\t" + "Б" * 160_000 + "в?"
        clean = beginning + "ё " + "б" * 160_000 + "в?"

        folder, database = prepare("blocks", {"sample.txt" => raw})
        expected = reference([clean])

        successful("build", folder, database)
        verify_database(database, expected)

        ["!ё ", "б" * 13, "б" * 12 + "в"].each do |prefix|
            verify_query(database, prefix, expected)
        end

        baseline = snapshot(database)

        hooks = {
        "after_commit" => <<~RUBY,
        require "sqlite3"

        module StopAfterCommit
        def transaction(*args, &block)
        result = super(*args, &block)
        Process.kill("KILL", Process.pid)
        result
        end
        end

        SQLite3::Database.prepend(StopAfterCommit)
        RUBY
        "before_commit" => <<~RUBY
        require "sqlite3"

        module StopBeforeCommit
        def transaction(*args)
        super(*args) do
        result = yield
        Process.kill("KILL", Process.pid)
        result
        end
        end
        end

        SQLite3::Database.prepend(StopBeforeCommit)
        RUBY
        }

        hooks.each do |name, source|
            hook = File.join(@root, "#{name}.rb")
            interrupted_database = File.join(@root, "#{name}.sqlite3")

            File.write(hook, source)

            output, error, status = command(
                "build",
                folder,
                interrupted_database,
                hook: hook
            )

            assert(
                status.signaled? && status.termsig == Signal.list.fetch("KILL"),
                "Не удалось выполнить аварийный тест #{name}:\n#{output}\n#{error}"
            )

            interrupted = snapshot(interrupted_database)

            if name == "after_commit"
                position = interrupted[:progress].first&.[](2)

                assert(
                    position && position > 0 && position < raw.bytesize,
                    "Не сохранена промежуточная позиция после блока"
                )
            else
                assert(
                    interrupted.values.all?(&:empty?),
                    "Незавершённая транзакция оставила частичные данные"
                )
            end

            successful("build", folder, interrupted_database)

            assert(
                snapshot(interrupted_database) == baseline,
                "После восстановления #{name} получены другие данные"
            )
        end

        puts "OK: разрыв UTF-8 на границе блока и сохранение контекста"
        puts "OK: авария до COMMIT и после COMMIT, восстановление без дублей"
    end

    def test_changed_file
        folder, database = prepare("changed", {"sample.txt" => "абаба"})

        successful("build", folder, database)
        before = snapshot(database)

        File.write(File.join(folder, "sample.txt"), "абабя")

        output, error, status = command("build", folder, database)

        assert(!status.success?, "Изменённый файл не был отклонён")

        assert(
            (output + error).include?("Файл изменился"),
            "Не выведено объяснение изменения файла"
        )

        assert(
            snapshot(database) == before,
            "При обнаружении изменения файла база была изменена"
        )

        puts "OK: изменение исходного файла обнаружено"
    end

    private :assert, :command, :successful, :prepare, :reference,
          :expanded_counts, :verify_database, :verify_query,
          :snapshot, :test_small, :test_normalization,
          :expected_for_query, :test_files, :test_all_lengths,
          :test_empty, :test_blocks_and_recovery, :test_changed_file
end

begin
    StatisticsTest.new.run
rescue StandardError => error
    warn "\nFAIL: #{error.message}"
    exit 1
end
