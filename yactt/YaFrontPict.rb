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

# PICTフロントと標準形式（積和形式）の変換を行うクラス

# PICTパラメタの読み込み
class YaFrontPict
  def initialize(params)
    @options = params.options
    @pict_model_file = @options[:model_file] # 定義ファイル
    @pict_seed_file = @options[:seed_file]   # -iで指定したシードファイル
    
    @pict_params = {}     # PICTで定義されたパラメタ
    
    @solver_params = {}   # 汎用のソルバで使用するパラメタ
    @negative_values = [] # ネガティブが指定された値の配列
    @restricts = []       # 制約の情報
    @submodels = []       # サブモデルの情報
    @base_tests = nil     # シードとして与える基本的なテスト
    
    @name_map = {}       # ソルバのパラメタ名→PICTのパラメタ名のマップ
    @name_map2 = {}      # PICTのパラメタ名→ソルバのパラメタ名のマップ
    @param_expr       # パラメタ定義文の正規表現
    @sub_expr         # 部分的な強度の重み指定の正規表現
    @ifclause_expr    # if文の式の正規表現
    @uncond_expr      # 無条件制約の正規表現
    @term_expr        # 制約の正規表現
    @logic_ope = { "AND" => "*", "OR" => "+", "NOT" => "-" }
    @value_delim = @options[:value_delimiter] || "," # 値の区切り文字
    @alias_delim = @options[:alias_delimiter] || "|" # 別名の区切り文字
    @negative_prefix = @options[:negative_prefix] || "~"     # ネガティブテストの文字
    @rotate_hash = {}  # aliasがある場合の結果の表示に使うハッシュ

    set_reg_expr      # if文の式などの評価に使う正規表現を設定
    analyze_model_file()
    analyze_seed_file()
  end
  
  # アクセサ（getterのみ）の定義
  attr_reader :solver_params, :negative_values, :restricts, :submodels, :base_tests, :pict_params

  # if文の式などの評価に使う正規表現を設定
  def set_reg_expr
    @param_expr    = /^\s*([^:]+):\s*(.+)$/
    @value_expr    = /^(#{@negative_prefix})?([^\(]+)(?:\((\d+)\))?$/
    @sub_expr      = /^\s*\{\s*(.+?)\s*\}\s*\@\s*(\d+)/
    @ifclause_expr = /^\s*IF\s+(.+?)\sTHEN\s+(.+?)(?:\sELSE\s+(.+?))?;/mi
    @uncond_expr   = /^\s*([\[\(].+?);/m
    
    prm_expr   = '\[(.+?)\]'
    ope_expr   = '(\=|\<\>|\>\=|\<\=|\>|\<|LIKE|IN)'
    val_expr   = '(?:(\-?\d+|\".+?\")|\[(.+?)\]|\{(.+?)\})'
    @term_expr = /#{prm_expr}\s*#{ope_expr}\s*#{val_expr}/i
    
    # 制約条件の各要素のシンタックス（不正な文字列の検出のため）
    @restrict_expr = /(?:\s+|[\(\)\*\+\-]|\@p\d+_\d+)/

  end
  
  # モデルファイルの解析
  def analyze_model_file()
    content = IO.read(@pict_model_file) rescue raise("Model file(#{@pict_model_file}) not found")
    
    # コメントの削除
    content.gsub!(/#.+$/, "")
    
    # パラメタの定義部分の解析（解析終了後削除）
    content.gsub!(@param_expr){
      param = $1
      values = $2
      work = values.gsub(/\s+/, "").split(@value_delim)
      # 重みは解析対象外
      param_collate = @options[:case_sensitive]?param:param.downcase
      @pict_params[param_collate] = work.map{|value|
        if(!md = value.match(@value_expr))
          raise "value (#{value}) error"
        end
        current_value = md[2].split(@alias_delim)
        collate = @options[:case_sensitive]?current_value:current_value.map{|elem| elem.downcase}
        is_negative = (md[1] == @negative_prefix)
        waight_value = md[3].to_i 
        { :param => param, :value => current_value, :collate => collate,
          :negative => is_negative, :weight => waight_value }
      }
      # puts "param=[#{param}] collate=[#{param_collate}] values=#{@pict_params[param_collate]}"
      ""
    }
    analyze_params
    
    # サブモデル定義部分の解析（解析終了後削除）
    content.gsub!(@sub_expr) {
      params = $1
      strength = $2
      submodel = {:params => {}, :strength => strength.to_i}
      params.split(@value_delim).each do | param |
        param.gsub!(/^\s+|\s+$/, "")
        param_collate = @options[:case_sensitive]?param:param.downcase
        solver_name = @name_map2[param_collate]
        submodel[:params][solver_name] = @solver_params[solver_name]
      end
      @submodels.push submodel
      ""
    }
        
    #IFの定義部分の解析（解析終了後削除）
    content.gsub!(@ifclause_expr) {
      if_clause = $1
      then_clause = $2
      else_clause = $3
      restrict = {
        :if   => analyze_restrict("if", if_clause),
        :then => analyze_restrict("then", then_clause),
        :else => analyze_restrict("else", else_clause)
      }
      @restricts.push restrict
      ""
    }
    
    #無条件制約の定義部分の解析（解析終了後削除）
    content.gsub!(@uncond_expr) {
      uncond_clause = $1
      @restricts.push({ :uncond => analyze_restrict("uncond", uncond_clause) })
      ""
    }
    # pp @restricts
    
    # 空行の削除
    content.gsub!(/^\s+$/, "")
    
    # 解析対象以外の文字列が残っていた場合はエラー
    if(content.length > 0)
      raise "Syntax error in model file(#{@pict_model_file}). " +
            "Failed to analyze following line(s)\n#{content}"
    end
  end
  
  # パラメタの定義部分の解析
  def analyze_params()
    @pict_params.keys.each_with_index do | param_collate, i |
      # PICTパラメタとソルバパラメタの名称の変換マップの設定
      param_name = "@p#{i}"
      @name_map[param_name] = param_collate
      @name_map2[param_collate] = param_name

      # ソルバパラメタの設定
      @solver_params[param_name] = []
      @pict_params[param_collate].each_with_index do | elem, j|
        solver_name = "#{param_name}_#{j}"
        @solver_params[param_name].push  solver_name
        if(elem[:negative])
          # puts "negative: #{elem}"
          @negative_values.push solver_name
        end
      end
    end
    # pp @solver_params
  end
  
  # 制約の定義部分の解析
  def analyze_restrict(type, clause)
    if(clause)
      clause.gsub!(/\r?\n/, " ")
      # puts "#{type}_clause: #{clause}"
      clause.gsub!(@term_expr) {
        new_term = nil
        # puts "param: #{$1} ope: #{$2} value: #{$3} param2\: #{$4} val_list: #{$5}"
        param = $1
        ope   = $2
        param_collate = @options[:case_sensitive]?param:param.downcase

        if(!@pict_params[param_collate])
          raise "Invalid parameter [#{param}]"
        end

        if(value = $3)
          new_term = convert_term_value(clause, param_collate, ope, value)
        elsif(param2 = $4)
          param2_collate = @options[:case_sensitive]?param2:param2.downcase
          if(!@pict_params[param2_collate])
            raise "Invalid parameter #{param2}"
          end
          new_term = convert_term_param2(clause, param_collate, ope, param2_collate)
        elsif(val_list = $5)
          new_term = convert_term_val_list(clause, param_collate, ope, val_list)
        else
          raise "internal error"
        end
        
        # カッコをつけて返す
        "(#{new_term})"
      }
      clause.gsub!(/(or|and|not)/i) { @logic_ope[$1.upcase] }
      clause.gsub!(/\s+/, "")
    end
    # puts "clause: #{clause}"
    check_restrict_syntax(clause)
    clause
  end
  
  # 制約条件の文法のチェック
  def check_restrict_syntax(clause)
    if(clause)
      invalid_string = clause.gsub(@restrict_expr, "")
      if(invalid_string.length > 0)
        raise "Invalid restrict expression (#{invalid_string})"
      end
    end
  end

  # [Param] = valueのパターンの解析
  def convert_term_value(clause, param_collate, ope, value)
    param = @pict_params[param_collate][0][:param]
    new_term = ""
    case ope
    when "="
      value.gsub!(/^"|"$/, "")
      collate = @options[:case_sensitive]?value:value.downcase
      # 別名の場合、最初のエントリをサーチ
      if(index = @pict_params[param_collate].index {|info| info[:collate][0] == collate})
        new_term = "#{@name_map2[param_collate]}_#{index}"
      else
        raise "\"#{value}\" is not in [#{param}]"
      end
    when /like/i
      value.gsub!(/^"|"$/, "")
      collate = @options[:case_sensitive]?value:value.downcase
      new_elems = []
      @pict_params[param_collate].each_with_index do | elem, index |
        if( File.fnmatch(collate, elem[:collate][0]) )
          new_elems.push "#{@name_map2[param_collate]}_#{index}"
        end
      end
      new_term = new_elems.join("+")
    when ">=", "<=", "<>", ">", "<"
      ope = "!=" if(ope == "<>")
      new_elems = []
      @pict_params[param_collate].each_with_index do | elem, index |
        collate = @options[:case_sensitive]?value:value.downcase
        elem = elem[:collate][0]
        if(!elem.match(/^\d+$/))
          elem = "\"#{elem}\""
        end
        if( eval( "#{elem}#{ope}#{collate}") )
          new_elems.push "#{@name_map2[param_collate]}_#{index}"
        end
      end
      new_term = new_elems.join("+")
    else
      raise "invalid operation in #{clause}"
    end
    new_term
  end
  
  # [Param] = [Param2]のパターンの解析
  def convert_term_param2(clause, param_collate, ope, param2_collate)
    ope = "!=" if(ope == "<>")
    ope = "==" if(ope == "=")
    new_term = ""
    new_elems = []
    values1 = @pict_params[param_collate].map {|elem| elem[:collate]}
    values2 = @pict_params[param2_collate].map {|elem| elem[:collate]}
    values1.product(values2).each do | pair |
      if( eval( "#{pair[0]}#{ope}#{pair[1]}") )
        index1 = values1.index(pair[0])
        index2 = values2.index(pair[1])
        new_elems.push "#{@name_map2[param_collate]}_#{index1}*#{@name_map2[param2_collate]}_#{index2}"
      end
    end
    new_term = new_elems.join("+")
  end
  
  # [Param] IN { val1, val2 }のパターンの解析
  def convert_term_val_list(clause, param_collate, ope, val_list)
    raise "#{clause} error, [p] IN {v1, v2}" if(!ope.match(/^in$/i))
    param = @pict_params[param_collate][0][:param]
    val_list.gsub!(/^\s+|\s+$/, "")
    new_term = ""
    new_elems = []
    val_list.split(/\s*#{@value_delim}\s*/).each do | value |
      value.gsub!(/^"|"$/, "")
      collate = @options[:case_sensitive]?value:value.downcase
      # 別名の場合、最初のエントリをサーチ
      if(index = @pict_params[param_collate].index {|info| info[:collate][0] == collate})
        new_elems.push "#{@name_map2[param_collate]}_#{index}"
      else
        raise "\"#{value}\" is not in [#{param}]"
      end
    end
    new_term = new_elems.join("+")
  end

  # シードファイルの解析
  def analyze_seed_file()
    if(@pict_seed_file)
      content = IO.read(@pict_seed_file) rescue raise("Seed file(#{@pict_seed_file}) not found")
      lines = content.split("\n")
      
      # ヘッダ部分の読み込み
      header_elems = lines[0].split(/\t/)
      
      # コンテンツ部分の読み込み、変換
      tests = lines[1..-1].map do | line |
        values = line.split(/\s+/).map.with_index do | value, i |
          param_collate = @options[:case_sensitive]?(header_elems[i]):(header_elems[i].downcase)
          param = @name_map2[param_collate] || raise("Header [#{header_elems[i]}] is invalid in seed file")
          value_hashes = @pict_params[param_collate] || raise("Seed file invalid")
          offset = value_hashes.index {|value_hash| value_hash[:value].index(value)}
          "#{param}_#{offset}"
        end
        values.join("*")
      end
      @base_tests = tests.join("+")
    end
  end

  # 結果の表示（メインルーチンから呼び出される）
  def write(results)
    results_string = ""
    # ヘッダの表示
    results_string += @pict_params.values.map{|elem| elem[0][:param]}.join("\t") + "\n"
    print results_string
    
    # テストの表示
    results.each do | result |
      results_string += write_result(result)
    end
    results_string
  end
    
  # 生成された一つのテストを整形して出力
  def write_result(result)
    elems = result.split(/(?:\s+|\s*\*\s*)/).map do |solver_value|
      elem = solver_value.split("_")
      param_collate = @name_map[elem[0]]
      value_hash = @pict_params[param_collate][elem[1].to_i]
      aliases = value_hash[:value]
      negative = value_hash[:negative]
      @rotate_hash[solver_value] ||= 0
      value = aliases[@rotate_hash[solver_value]%(aliases.size())]
      @rotate_hash[solver_value] += 1
      ((negative)?(@negative_prefix):("")) + value
    end
    result_string = elems.join("\t") + "\n"
    print result_string
    result_string
  end
end

