# encoding: utf-8
require "pp"

# ZDDによる制約ソルバのクラス
class YaBackZdd
  require "nysol/zdd"
  
  # コンストラクタ
  def initialize(params, model_front)
    @zdd_params = {}    # ZDDで管理するパラメタ
    @command_options = params.options
    @model_front = model_front
    @params    = model_front.solver_params # 入力されたパラメタ
    @submodels = model_front.submodels     # サブモデル
    
    setZddParams(@params, @model_front)
  end
  
  # メインルーチン。指定された条件でテストを生成する
  def solve()
    strength = @command_options[:pair_strength] || 2

    if(strength >= @params.size())
      warn "Strength (#{strength}) is equal to or larger than No. of parameters (#{@params.size()}). Whole combination will be shown."
      strength = 0
    end
    test_set = @zdd_params[:current_tests]
    
    # Pairwiseで絞り込むか否か
    if(strength > 0)
      # test_set = pairwise_foo(test_set, strength)
      # test_set = pairwise(test_set, strength)
      test_set = pairwise_new(test_set, strength)
      test_set.each do | test_case |
        test_case.show
      end
    end
    
    # 結果のヘッダを表示
    @model_front.write_header()
    
    # 膨大なテスト項目になったときに待たせないようにZDD側の
    # eachで一項目ずつ出力する
    @zdd_params[:base_tests].each do | a_test |
      @model_front.write_result(a_test.to_s)
    end
    
    test_set.each do | a_test |
      @model_front.write_result(a_test.to_s)
    end
  end

  # ZDDのパラメタ設定
  def setZddParams(params, model_front)
    restricts = model_front.restricts
    negative_values = model_front.negative_values
    base_tests = model_front.base_tests
    
    # パラメタ定義のセット
    test_set  = ZDD.constant(1)
    params.each do | param_name, values |
      @zdd_params[param_name]  = ZDD.constant(0)
      values.each do | value_name |
        ZDD.symbol(value_name, 1)
        current_item = ZDD.itemset(value_name)
        eval("#{value_name} = current_item")
        @zdd_params[param_name] += current_item
      end
      test_set *= @zdd_params[param_name]
    end
    
    old_count = test_set.count
    
    # 制約条件のセット
    @zdd_params[:restrict] = restricts.map { | restrict |
      results = {}
      restrict.each do | key, value |
        results[key] = (value)?(eval(value)):nil 
      end
      results
    }
    # 明示的に指定された制約条件に従って項目を削減
    test_set = apply_restrict(test_set)
    
    # ネガティブ値による制約に従って項目を削減
    test_set = negative_constraint(test_set, negative_values)

    puts "count #{old_count} --> #{test_set.count}"
    
    # 制約条件を満たすすべてのテスト項目
    @zdd_params[:whole_tests] = test_set
    
    # シードとして与えられた基本的なテスト
    @zdd_params[:base_tests] = set_base_tests(test_set, base_tests)
    
    # 新たに作成なテストの全体
    @zdd_params[:current_tests] = @zdd_params[:whole_tests] - @zdd_params[:base_tests]
  end

  # 制約条件に従い、テスト項目を削減
  def apply_restrict(test)
    @zdd_params[:restrict].each do | restrict |
      if(restrict[:if] && restrict[:else])
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test.restrict(restrict[:else]))
      elsif(restrict[:if])
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test)
      elsif(restrict[:uncond])
        test = test.restrict(restrict[:uncond])
      else
        raise "internal error, restrict type invalid"
      end
    end
    test
  end

  # 制約条件に従い、テスト項目を削減
  def apply_restrict2(test)
    @zdd_params[:restrict].each do | restrict |
      if(restrict[:if] && restrict[:else])
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test.restrict(restrict[:else]))
      elsif(restrict[:if])
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test)
      elsif(restrict[:uncond])
        test = test.restrict(restrict[:uncond]).iif(test.restrict(restrict[:uncond]), test)
      else
        raise "internal error, restrict type invalid"
      end
    end
    test
  end

  # ネガティブ値による制約に従って項目を削減(処理方法の工夫が必要）
  def negative_constraint(test_set, negative_values)
    if(negative_values.size() > 0)
      negative_condition = ZDD.constant(0)
      negative_values.each do | negative_value |
        negative_condition += ZDD.itemset(negative_value)
      end
      
      # ネガティブ値が重なっているテスト項目を削減
      test_set -= test_set.restrict((negative_condition * negative_condition)/2)
      
      #pp test_set
      # 古い論理。これよりは上記の処理のほうがベターだと思うが...
      # negative_condition = ZDD.constant(1)
      # negative_values.each do | negative_value |
      #   negative_condition += ZDD.itemset(negative_value)
      # end
      # max_size = @params.keys.size()
      # test_set = (negative_condition *test_set).permitsym(max_size).termsLE(2)
      # test_set = (test_set == test_set)
    end
    test_set
  end

  # シードとして与える基本的なテストをZDDのモジュールに変換
  def set_base_tests(test_set, base_tests)
    zdd_base_tests = ZDD.constant(0)
    if(base_tests)
      # ZDD形式に変換し、全テストのサブ集合であることを確認
      zdd_base_tests = eval(base_tests)
      diff = (test_set - zdd_base_tests) < 0
      if(diff.count > 0)
        raise "Invalid seeds #{diff}"
      end
    end
    zdd_base_tests
  end
  
  # 最初の項を返す
  def first_term(terms)
    terms.each {|term| return term}
  end

  # ランダムな項を返す
  def random_term(terms)
    offset = rand(terms.count)
    count = 0
    terms.each do |term|
      return term if(offset == count)
      count += 1
    end
    raise "internal error"
  end

  # オールペアの仮実装
  def pairwise_foo(test, strength = 2)

    results = ZDD.constant(0)
    all_combinations = get_all_combi(strength)
    max_size = @params.keys.size()
    # combi_size =  @params.keys.combination(strength).size()
    # pp all_combi
    # puts "combi_size #{combi_size}"
    while(true)
      print "all_combination: "
      pp all_combinations
      # 現状の組み合わせからテスト項目を組み立て
      result = ZDD.constant(1)
      all_combinations.shuffle.each do | temp_combi |
        next if(temp_combi.count() == 0)
        last_result = result
        result *= temp_combi
        result = result.permitsym(max_size)
        puts result.count
        # 途中で満たすものが無くなった場合は最後の結果を使う
        if(result.count == 0)
          result = last_result
          break
        end
      end
      result = (result == result)  # 係数の削除
      result = result.maxcover()
      # 組み立てたもののうち、制約条件を満たしているものを選択
      # result = (result == @zdd_params[:current_tests])
      result = result.meet(@zdd_params[:current_tests])
      puts "match count = #{result.count}"
      
      puts "result=" + result.inspect
      
      # 結果の中から素の組合せを列挙　⇒　没
      # prime = result.delta(result)
      #new_result = ZDD.constant(0)
      #while(result.size() > 0)
      #  item = first_term(result)
      #  new_result += item
      #  break
      #  result = result.delta(item)/item
      #end
      new_result = first_term(result)
      new_result = (new_result == new_result)
      puts "new_result=" + new_result.to_s
      if((results/new_result).count() > 0)
        pp results
        pp (results/new_result)
        exit
        next
      end
      results += new_result
      
      # 新しくできた結果から組合せを削除
      count = 0
      all_combinations = all_combinations.map do | temp_combi |
        combi = temp_combi.meet(new_result)
        combi -= combi.permitsym(strength-1)
        temp_combi -= combi
        count += temp_combi.count
        temp_combi
      end
      puts "count=#{count}"
      break if(count == 0)
    end
    pp results
    puts "total count=#{results.count}"
    exit
    
    
    combi_array = get_combi_array(all_combi)
    sample_num = combi_array.size()
    sample_array = combi_array.shuffle[0...sample_num]
    sample_combi = sample_array.inject(:+)
    sample_combi.show
    
    foo = (sample_combi * sample_combi * sample_combi* sample_combi* sample_combi* sample_combi)
    puts foo.count
    foo = (foo == @zdd_params[:current_tests])
    puts foo.count
    foo = apply_restrict(foo)
    puts foo.count
    pp foo
    
    exit
    test_array = get_test_array()
    
    test_case_num = @command_options[:try_count] || 8

    calc_all_pairs(all_combi, test_array, strength, test_case_num)
  end

  # オールペアの仮実装
  def pairwise(test_set, strength = 2)

    all_combi = get_all_combination(@params, strength)
    test_array = get_test_array(test)
    
    test_case_num = @command_options[:try_count] || 40
    calc_all_pairs_sample(all_combi, test_set, strength, test_case_num)
  end

  # オールペアの仮実装
  def pairwise_new(test_set, strength = 2)

    # 全体の組合せを得る
    all_combi = get_all_combination(@params, strength)
    
    # サブモデルの組合せを得る
    @submodels.each do | submodel |
      pp submodel
      if(submodel[:strength] > strength)
        all_combi += get_all_combination(submodel[:params], submodel[:strength])
      end
    end
    
    # 各項のうち、包含しているものを削除（処理方法の再検討要）
    pp all_combi.count
    work = all_combi.freqpatC(2)
    work -= work.permitsym(strength - 1)
    all_combi -= work
    puts "***"
    pp all_combi.count
    pp all_combi
    puts "***"
    
    # 制約項目に反しているものの削除しようと思ったが、既存処理ではダメだった
    # 制約項目とは関係ない項まで削除されてしまう。
    # all_combi = apply_restrict2(all_combi)
    # pp all_combi
    # exit
    # 性能的に問題な処理だが、いまのところこのアルゴリズム
    invalid_combi = ZDD.constant(0)
    all_combi.each do | term |
      if((test_set/term).count == 0)
        invalid_combi += term
      end
    end
    all_combi -= invalid_combi
    
    test_case_num = @command_options[:try_count] || 8
    calc_all_pairs_sample(all_combi, test_set, strength, test_case_num)
  end

  # ある強度でのすべての組合せを得る(rubyのcombinationを使った実装）
  def get_all_combi(strength)
    all_combi = ZDD.constant(0)
    all_combinations = []
    @params.keys.combination(strength).each do | keys |
      temp_combi = @zdd_params[keys[0]]
      (1...strength).each do |i|
        temp_combi *= @zdd_params[keys[i]]
      end
      all_combi += temp_combi
      all_combinations.push temp_combi
    end
    puts "combi count = #{all_combi.count}"
    all_combinations
  end
    
  # ある強度でのすべての組合せを得る(zdd側のライブラリを使った実装）
  def get_all_combination(params, strength)
    test_combi = ZDD.constant(1)
    params.each do | param_name, values |
      test_combi *= (@zdd_params[param_name] + 1)
    end
    # ある強度でのすべての組合せ
    all_combi = test_combi.permitsym(strength) - test_combi.permitsym(strength-1)
    puts "combi count = #{all_combi.count}"
    all_combi
  end
    
  # テストを配列に変換（これは大きいときに破たんする処理）
  def get_test_array(test_set)
    test_array = []
    test_set.each do | a_test |
      test_array.push a_test
    end
    test_array
  end
    
  # 組み合わせを配列に変換（これは大きいときに破たんする処理）
  def get_combi_array(all_combi)
    combi_array = []
    all_combi.each do | combi |
      combi_array.push combi
    end
    combi_array
  end
    
  # 削除する候補を得る
  def get_remove_new(sample, all_combi, strength)
    puts "****"
    min_match = 9999999999
    remove = nil
    sample.each do | term |
      current = all_combi.meet(term)
      current -= current.permitsym(strength-1)
      if(current.count < min_match)
        pp term
        pp current.count
        remove = term
        min_match = current.count
      end
    end
    remove
  end
    
  # 削除する候補を得る
  def get_remove(sample, all_combi, dup_combi, strength)
    puts "****"
    min_match = 9999999999
    remove = nil
    sample.each do | term |
      dup = dup_combi.meet(term)
      dup -= dup.permitsym(strength-1)
      all = all_combi.meet(term)
      all -= all.permitsym(strength-1)
      count = all.count - dup.count
      if(count < min_match)
        pp term
        pp count
        remove = term
        min_match = count
      end
    end
    remove
  end
    
  # 削除する候補を得る
  def get_remove_old(sample, strength)
    freq_count = 2
    remove = ZDD.constant(0)
    while(true)
      freqpat = sample.freqpatM(freq_count)
      freqpat -= freqpat.permitsym(strength-1)
      puts "freq_count=#{freq_count} freqpat=#{freqpat.count}"
      if(freqpat.count == 0)
        puts "*** remove #{remove.count}"
        # pp remove
        break
      end
      remove = sample.restrict(freqpat)
      freq_count += 1
    end
    random_term(remove)
  end
    
  # カバーできていない組合せを得る
  def check_cover(all_combi, sample, strength)
    # 頻度も含めた出現組み合わせ
    combi = all_combi.meet(sample)
    combi -= combi.permitsym(strength-1)
    # 重複している組合せ
    dup_combi = combi.termsGE(2)
    dup_combi = (dup_combi == dup_combi)
    dup_combi = (all_combi == dup_combi)
    # 重みの削除
    flat_combi = (combi == combi)
    # カバーされていない組み合わせ
    #puts "***"
    #pp flat_combi
    no_combi = ((all_combi - flat_combi) > 0)
    #puts "*** no_combi"
    #pp no_combi
    if(no_combi.count == 0)
      puts "Get it!"
      @model_front.write(get_test_array(sample).map{|term| term.to_s})
      # sample.each {|term| puts term.to_s}
      exit
    end
    [no_combi, dup_combi]
  end
    
  # すべてのペアを列挙
  def calc_all_pairs_sample(all_combi, test_set, strength, test_case_num)
    test_array = get_test_array(test_set)
    try_count = 0
    test_set = @zdd_params[:current_tests]
    puts test_array.size()
    max_match = 0
    min_unmatch = 99999999
    no_combi = nil
    dup_combi = nil
    sample = nil
    100.times do | try_count |
      # サンプルのデータ
      test_array.shuffle!
      current_sample = test_array[0...test_case_num].inject(:+)
      (no_combi, dup_combi) = check_cover(all_combi, current_sample, strength)
      if(no_combi.count < min_unmatch)
        puts "no_combi = #{no_combi.count} dup_combi = #{dup_combi.count} count = #{try_count}"
        puts "no_combi"
        pp no_combi
        puts "dup_combi"
        pp dup_combi
        sample = current_sample
        min_unmatch = no_combi.count
      end
    end
    puts "*** sample #{sample.count}"

    pp sample
    while(true)
      test_set -= sample
      test_array = get_test_array(sample)
      
      5.times do | i |
        
        remove = get_remove(sample, all_combi, dup_combi, strength)
        # remove = get_remove_new(sample, all_combi, strength)
        pp remove
        sample -= remove
        (temp_no_combi, temp_dup_combi) = check_cover(all_combi, sample, strength)
        puts "### rest = #{temp_no_combi.count}"
        exit
        min_match = min_unmatch
        test_set.each do | term |
          new_sample = sample + term
          # puts "*** new_sample #{new_sample.count}"
          # pp new_sample
          (new_no_combi, new_dup_combi) = check_cover(all_combi, new_sample, strength)
          puts "### rest = #{new_no_combi.count}"
          if(new_no_combi.count < min_match)
            min_match = new_no_combi.count
          end
        end
        
        exit
        alter = test_array.shuffle[0...remove.count].inject(:+)
        puts "*** alter #{alter.count}"
        pp sample - alter
        
        sample += alter
        puts "*** sample #{sample.count}"
        pp sample
        
        remove.each do | term |
          test_array.push term
        end
        
        (new_no_combi, new_dup_combi) = check_cover(all_combi, sample, strength)
        puts "### rest = #{no_combi.count}"
        if(new_no_combi < no_combi)
          no_combi = new_no_combi
        else
          sample -= alter
          sample += remove
        end
      end
      puts "### rest = #{no_combi.count}"
      exit

      pp 2
      pp sample.freqpatA(2)
      pp 3
      pp sample.freqpatA(3)
      pp 4
      pp sample.freqpatA(4)
      exit
      combi.show
      
      
      
      # pp combi.to_a.sort
      # pp no_combi.to_a.sort
      if(max_match < combi.count)
        max_match = combi.count
        min_unmatch = no_combi.count
        puts "try=#{try_count} combi=#{combi.count} no_combi=#{no_combi.count}"
      end
        
      sample.show if(no_combi.count == 0)
      break if(no_combi.count == 0)
      try_count += 1
      puts try_count if((try_count % 1000) == 0)
      # exit if try_count == 10
    end
    puts try_count
    exit
    pp work2.termsGE(2)

    current_combi = []
    all_combi.each do | combi |
      # puts "combi=#{combi} result=#{work/combi}"
      current_combi.push combi if((work/combi).count > 0)
    end
    pp current_combi
    exit 
    
    puts ZDD.symbol
    puts zdd_params[:current_tests].count
    zdd_params
  end

  # すべてのペアを列挙
  def calc_all_pairs_all(all_combi, test_array, strength, test_case_num)
    try_count = 0
    puts test_array.size()
    puts test_array.combination(100).size()
    test_array.combination(100).each do | current_array |
      # サンプルのデータ
      sample = current_array.inject(:+)
      
      # 頻度も含めた出現組み合わせ
      combi = all_combi.meet(sample)
      combi -= combi.permitsym(strength-1)
      # combi.show
      
      # 重みの削除
      flat_combi = (combi == combi)
      
      # カバーされていない組み合わせ
      no_combi = (all_combi - flat_combi)
      
      # pp combi.to_a.sort
      # pp no_combi.to_a.sort
      sample.show if(no_combi.count == 0)
      # break if(no_combi.count == 0)
      try_count += 1
      puts try_count if((try_count % 10000) == 0)
    end
    puts try_count
    exit
    pp work2.termsGE(2)
  end
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

# プロファイラを有効にするためのおまじない
module ZDD
  #def self.to_s
  #  self.name
  #end
end
