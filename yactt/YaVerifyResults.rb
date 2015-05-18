# encoding: utf-8

#    Yacct: an experimental implementation of PICT clone.
#    Copyright (C) 2015, Ikoma, Mikio
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "pp"

# バックエンドが出力したデータをZDDで検証するクラス
class YaVerifyResults
  require "./zdd/lib/zdd"
  
  # コンストラクタ
  def self.verify(params, model_front, results)
    command_options = params.options
    solver_params   = model_front.solver_params # 入力されたパラメタ
    submodels = model_front.submodels     # サブモデル
    strength = command_options[:strength] || 2
    
    zdd_params = {}    # ZDDで管理するパラメタ
    test_set = get_test_set(solver_params, model_front, zdd_params)
    
    zdd_results = eval(results.join("+"))
    all_combi = get_whole_combination(zdd_params, solver_params, test_set, submodels, strength)
    
    puts "** test_set"
    pp test_set.count
    #puts "** all_combi"
    #pp all_combi
    puts "** zdd_results"
    pp zdd_results.count
    
    check_results(test_set, all_combi, zdd_results, strength, model_front)
  end
  
  # ZDDのパラメタ設定
  def self.get_test_set(solver_params, model_front, zdd_params)
    restricts = model_front.restricts
    negative_values = model_front.negative_values
    base_tests = model_front.base_tests
    
    # パラメタ定義のセット
    test_set  = ZDD.constant(1)
    solver_params.each do | param_name, values |
      zdd_params[param_name]  = ZDD.constant(0)
      values.each do | value_name |
        ZDD.symbol(value_name, 1)
        current_item = ZDD.itemset(value_name)
        eval("#{value_name} = current_item")
        zdd_params[param_name] += current_item
      end
      test_set *= zdd_params[param_name]
    end
    
    old_count = test_set.count
    
    # 制約条件のセット
    # pp restricts
    zdd_params[:restrict] = restricts.map { | restrict |
      results = {}
      restrict.each do | key, value |
        results[key] = (value)?(eval(value)):nil 
      end
      results
    }
    pp zdd_params[:restrict]
    # 明示的に指定された制約条件に従って項目を削減
    test_set = apply_restrict(zdd_params, test_set)
    
    # ネガティブ値による制約に従って項目を削減
    test_set = negative_constraint(test_set, negative_values)

    # puts "count #{old_count} --> #{test_set.count}"
    
    # 制約条件を満たすすべてのテスト項目
    test_set
  end

  # 制約条件に従い、テスト項目を削減
  def self.apply_restrict(zdd_params, test)
    zdd_params[:restrict].each do | restrict |
      if(restrict[:if] && restrict[:else])
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test.restrict(restrict[:else]))
      elsif(restrict[:if])
        pp test
        test = test.restrict(restrict[:if]).iif(test.restrict(restrict[:then]), test)
        pp test
        exit
      elsif(restrict[:uncond])
        test = test.restrict(restrict[:uncond])
      else
        raise "internal error, restrict type invalid"
      end
    end
    test
  end

  # ネガティブ値による制約に従って項目を削減(処理方法の工夫が必要）
  def self.negative_constraint(test_set, negative_values)
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

  # オールペアの仮実装
  def self.get_whole_combination(zdd_params, solver_params, test_set, submodels, strength = 2)

    # 全体の組合せを得る
    all_combi = get_basic_combination(zdd_params, solver_params, strength)
    
    # サブモデルの組合せを加える
    submodels.each do | submodel |
      # pp submodel
      if(submodel[:strength] > strength)
        all_combi += get_basic_combination(zdd_params, submodel[:params], submodel[:strength])
      end
    end
    
    # 各項のうち、包含しているものを削除（処理方法の再検討要）
    # pp all_combi.count
    work = all_combi.freqpatC(2)
    work -= work.permitsym(strength - 1)
    all_combi -= work
    
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
    
  end

  # ある強度でのすべての組合せを得る(zdd側のライブラリを使った実装）
  def self.get_basic_combination(zdd_params, solver_params, strength)
    test_combi = ZDD.constant(1)
    solver_params.each do | param_name, values |
      test_combi *= (zdd_params[param_name] + 1)
    end
    # ある強度でのすべての組合せ
    all_combi = test_combi.permitsym(strength) - test_combi.permitsym(strength-1)
    # puts "combi count = #{all_combi.count}"
    all_combi
  end
  
  # 結果の確認
  def self.check_results(test_set, all_combi, zdd_results, strength, model_front)
  
    # テストが(制約後の)全集合のサブ集合であることの確認
    invalid_tests = ((test_set - zdd_results)  < 0)
    if(invalid_tests.count == 0)
      puts "== All tests are valid"
    else
      puts "== ERROR: following tests are invalid"
      model_front.write(invalid_tests.to_s.split(/\s*\+\s*/))
    end
    
    # テストが、ペアワイズの組合せをすべて満足していることの確認
    combi = all_combi.meet(test_set)
    combi -= combi.permitsym(strength-1)
    # 重みの削除
    flat_combi = (combi == combi)
    no_combi = ((all_combi - flat_combi) > 0)
    if(no_combi.count == 0)
      puts "== The tests satisfies pairwise requirements"
    else
      puts "== ERROR: following combinations are not satisfied"
      no_combi.show
    end
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
