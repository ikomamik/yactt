# encoding: utf-8

# 汎用的な組合せテスト項目生成ツール
#   ruby yact.rb modelfile  # PICTで指定するモデルファイルを指定
#   ruby yact.rb --help     # その他のオプションは、--helpで確認可能

Version = "00.00.03"

$debug = false

require "./YaParameters"

# コマンドとして呼ばれた時のルーチン
def  main(command, argv)

  # オプションの解析
  params = YaParameters.new(argv)
  
  # yacttの実行
  exec_yactt(params)
end

# ライブラリとして呼ばれた時のルーチン
def yactt_lib(options)
  params = YaParameters.new(nil, options)
  exec_yactt(params)
end

# Yacttの実行
def exec_yactt(params)
  require "pp"; pp params
  # PICTのパラメタから中間オブジェクトを生成
  require "./YaFrontPict"
  model = YaFrontPict.new(params)

  # バックエンド指定によってテスト生成エンジンを設定
  solver = nil
  case params.options[:back_end]
  when /cit/i
    if(params.options[:pair_strength] > 1)
      # CIT-BACHのバックエンドを登録
      require "./YaBackCitBach"
      solver = YaBackCitBach.new(params, model)
    else
      # 強度１はサポートしていないので自力で解析
      require "./YaBackZddOne"
      solver = YaBackZddOne.new(params, model)
    end
  when /acts/i
    # ACTSのバックエンドを登録
    require "./YaBackActs"
    solver = YaBackActs.new(params, model)
  when /zdd/i
    # ZDDのバックエンドを登録(未完)
    require "./YaBackZdd"
    solver = YaBackZdd.new(params, model)
  else
    raise "back-end (#{params.options[:back_end]}) is invalid"
  end
  
  # 正規形のテスト生成(resultsはeachメソッドを持つ(複数の)テスト）
  results = solver.solve()
  
  # フロントのフォーマットでテスト出力
  results_string = model.write(results)

  # 結果のチェック
  if(params.options[:verify_results])
    verify_results(params, model, results)
  end
  
  results_string
end

# 結果のチェック
def verify_results(params, model, results)
  require "./YaVerifyResults"
  YaVerifyResults.verify(params, model, results)
end

# バックエンド実行時のstderrをファイルに出力先変更
def save_stderror
  # 標準エラーの退避
  stderr_save = STDERR.dup
  
  filename = "./temp/stderr_#{Process.pid}.txt"
  new_fd = open(filename, "w") rescue raise("#{filename} open failed. rc: #{$?}\n")
  STDERR.reopen(new_fd)
  stderr_save
end

# バックエンド実行時のstderrを元に戻す
def recover_stderr(stderr_save)
  STDERR.flush
  new_fd = STDERR.dup
  new_fd.close()
  STDERR.reopen(stderr_save)
end


# デバッグプリント
def dbgpp(variable, title = nil)
  if($debug)
    puts "===#{title}===" if title
    if(String === variable)
      puts variable
    else
      pp variable
    end
  end
end

# コマンドとして実行された時の処理
if __FILE__ == $0
  begin
    # コマンド名と引数をメインルーチンに渡す
    main($0, ARGV)

    # エラー検出時の処理
  rescue RuntimeError => ex
    $stderr.puts "yactt: " + ex.message
    exit(1)
  end
end

