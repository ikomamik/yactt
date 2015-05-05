#!/usr/bin/ruby
# encoding: utf-8

require 'optparse'

# オプションの解析、管理するクラス
class YaParameters
  def initialize(args, options = nil)
    if(options)
      @options = options
    else
      # オプションの解析
      @options = get_options(args)
    end
  end
  
  attr_accessor :options

  # コマンドに指定されたフラグの解析
  def get_options(argv)
    options = {
      :pair_strength => 2,
      :back_end => "cit"
    }
    
    # Windows風のオプション指定した場合のUNIX風への変換
    argv = preprocess_arg(argv)
    
    OptionParser.new do | opt |
      opt.banner = "Usage: yact  [-o strength | -w]  [-e seeding-rows] [-r random-seed] model_file"
      
      # ペアの強度
      opt.on('-o', '--pair_strength=integer', 'strength of pairs. default is 2') do | strength |
        options[:pair_strength] = strength.to_i rescue "-o must be integer"
      end

      # 全組合せ出力
      opt.on('-w', '--whole_combinations', 'specify if print whole combinations') do | v |
        options[:pair_strength] = 0  # 強度ゼロが全組合せを示す
      end

      # ベースとなるテストが格納されたファイルを指定
      opt.on('-e', '--seed_file=file_name', 'specify file name as seeding tests') do | file_name |
        options[:seed_file] = file_name
      end

      # ランダムのシード
      opt.on('-r', '--random_seed=integer', 'strength of pairs') do | seed |
        options[:random_seed] = seed.to_i
      end

      # 値の区切り文字
      opt.on('-d', '--value_delimiter=letter', 'delimiter for values') do | letter |
        raise "Delimiter (#{letter}) must be a letter" if(letter.length != 1)
        options[:value_delimiter] = letter
      end

      # 別名の区切り文字
      opt.on('-a', '--alias_delimiter=letter', 'delimiter for aliases') do | letter |
        raise "Delimiter (#{letter}) must be a letter" if(letter.length != 1)
        options[:alias_delimiter] = letter
      end

      # ネガティブテストのID
      opt.on('-n', '--negative_prefix=letter', 'prefix for negative value') do | letter |
        raise "Negative-prefix (#{letter}) must be a letter" if(letter.length != 1)
        options[:negative_prefix] = letter
      end

      # バックエンドのエンジン指定
      opt.on('-b', '--back_end=engine', 'back-end test generator') do | engine |
        options[:back_end] = engine
      end

      # 英字の大文字小文字を意識する場合の指定
      opt.on('-c', '--case_sensitive', 'case-sensitive mode') do | case_sense |
        options[:case_sensitive] = case_sense
      end

      # 結果の検証の指定
      opt.on('--verify_results', 'verify results from solver') do | v |
        options[:verify_results] = true
      end
      
      # タイムアウト秒数(浮動小数点)の指定
      opt.on('--timeout=SEC', 'specify time limit (seconds) for solver') do | seconds |
        options[:timeout] = seconds.to_f
      end
      
      # デバッグ情報出力
      opt.on('--verbose', 'print detail information to consol') do | v |
        options[:verbose] = true
      end
      
      # 明示的に項目数を指定する場合の数（デバッグ用）
      opt.on('--try_count=integer', 'ONLY FOR INTERNAL USE. specify try count') do | count |
        options[:try_count] = count.to_i
      end
      
      opt.parse!(argv)
      
      # 位置パラメタはモデルファイルのみ
      if(argv.size == 1)
        options[:model_file] = argv[0]
      else
        raise "Syntax error.\n\n#{opt.banner}\n\nyact --help for more detail."
      end
    end
    
    options
  end
  
  # Windows風のオプション指定した場合のUNIX風への変換
  def preprocess_arg(argv)
    argv.map do | arg |
      if(md = arg.match(/^\/(\w)(?:\:(\w+))?$/))
        "-" + md[1] + (md[2] || "")
      else
        arg
      end
    end
  end

end
