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
require "tempfile"
require "kconv"

# CIT-BACHによるバックエンド処理
class YaBackCitBach
  
  # コンストラクタ
  def initialize(params, model_front)
    @command_options = params.options
    @model_front = model_front
    @params    = model_front.solver_params # 入力されたパラメタ
    @submodels = model_front.submodels     # サブモデル
    
    @cit_base = set_base_tests(@params, model_front.base_tests)
    @cit_params = setParams(@params, @model_front)
  end
  
  # CIT-BACHの実行
  def solve()
    param_fp = Tempfile.open("yact", "./temp")
    param_fp.puts @cit_params
    param_fp.flush
    param_path = param_fp.path

    base_tests_path = nil
    base_fp = nil
    if(@cit_base)
      base_fp = Tempfile.open("yact", "./temp")
      base_fp.puts @cit_base
      base_fp.flush
      base_tests_path = base_fp.path
    end
    
    # citディレクトリにあるjarを探索（バージョン番号が大きいものを選択）
    cit_jar = Dir.glob("cit/cit-bach*.jar").sort[-1]
    
    # CITのコマンドフラグの設定
    command = "java -jar #{cit_jar} -i #{param_path}"
    command += " -s #{base_tests_path}" if(@cit_base)
    command += " -random #{@command_options[:random_seed]}" if(@command_options[:random_seed])
    if(@command_options[:pair_strength] == 0)
      command += " -c all"
    else
      command += " -c #{@command_options[:pair_strength]}"
    end
    # puts command

    # 実行(systemコマンドや``では、タイムアウトを拾えないのでpopenで実行)
    results = ""
    read_buf = " " * 1024
    time_limit = @command_options[:timeout] || nil # nil時は無制限
    
    cmd_io = IO.popen(command, "r")
    tool_pid = cmd_io.pid
    while(true)
      is_read = IO.select([cmd_io], [], [], time_limit)
      if(!is_read)
        Process.kill(9, tool_pid)
        raise "time out"
      end
      
      # ブロックされないようにsysreadを発行。EOFの場合はループを抜ける。
      result = cmd_io.sysread(1024, read_buf) rescue break
      results += result
    end
    cmd_io.close()
    param_fp.close!
    base_fp.close! if(@cit_base)
    results = results.kconv(Kconv::UTF8).split("\n")

    # エラー時の処理
    if(!results[0].match(/^#SUCCESS,/))
      error_file = "cit_error.txt"
      File.open(error_file, "w") do |fp|
        fp.puts @cit_params
      end
      raise "CIT-BACH message: #{results[0]}\nCIT-BACH parameter file is #{error_file}"
    end
    
    # 結果を返す。最初の二行は関係ないので３行目から。
    results[2..-1].map{|result| result.tr(",", "*")}
  end
  
  # CitBachのパラメタ設定
  def setParams(params, model_front)
    cit_params = ""
    restricts = model_front.restricts
    negative_values = model_front.negative_values
    
    # パラメタ定義のセット
    cit_params += "# Parameters\n"
    params.each do | param_name, values |
      # 値の順番はランダムにする
      cit_params += "#{param_name} (#{values.shuffle.join(" ")})\n"
    end
    
    # サブモデルのセット
    cit_params += "# Submodels\n" if(@submodels.size > 0)
    @submodels.each do | submodel |
      params = submodel[:params].keys
      cit_params += "{#{params.join(" ")}}\n"
      warn "yact: submodel strength is unmatch" if(params.size != submodel[:strength])
    end

    # 制約条件のセット
    cit_params += "# Written constraints\n" if(restricts.size > 0)
    restricts.each do | restrict |
      cit_if = convert_restrict(restrict[:if])
      cit_then = convert_restrict(restrict[:then])
      cit_else = convert_restrict(restrict[:else])
      cit_uncond = convert_restrict(restrict[:uncond])
      if(cit_if && cit_else)
        cit_params += "(ite #{cit_if} #{cit_then} #{cit_else})\n"
      elsif(cit_if)
        cit_params += "(if  #{cit_if} #{cit_then})\n"
      elsif(cit_uncond)
        cit_params += "#{cit_uncond}\n"
      else
        raise "internal error, restrict type invalid"
      end
    end
    
    # ネガティブ値による制約のセット
    cit_params += "# Constraints of negative value\n" if(negative_values.size > 0)
    negative_values.each_with_index do | negative_value, i |
      other_values = negative_values[(i+1)..-1]
      if(other_values.size > 0)
        cit_params += "(if #{convert_item(negative_value)} "
        if(other_values.size > 1)
          cit_params += "(and #{other_values.map{|value| convert_false_item(value)}.join(" ")})"
        else
          cit_params += convert_false_item(other_values[0])
        end
        cit_params += ")\n"
      end
    end
    
    cit_params
  end

  # 制約条件部分の変換
  def convert_restrict(restrict)
    return nil unless(restrict)
    new_restrict = restrict.dup
    var_hash = {}
    var_count = 0
    # 積和形式をRubyの正規表現で強引に解析
    var_expr  = "@_\\d+"
    item_expr = "(?:@p\\d+_\\d+|#{var_expr})"
    pare_expr = "\\(#{item_expr}\\)"
    deny_expr = "\\-#{item_expr}"
    prod_expr = "(?:#{item_expr}\\*)+(#{item_expr})"
    sum_expr  = "(?:#{item_expr}\\+)+(#{item_expr})"
    
    while(true)
      new_restrict.gsub!(/#{pare_expr}|#{deny_expr}|#{prod_expr}|#{sum_expr}/) { | term |
        new_term = "@_#{var_count}"
        var_hash[new_term] = term
        var_count += 1
        new_term
      }
      break if(new_restrict.match(/^#{item_expr}$/))
    end
    #puts "****"
    #pp new_restrict
    #pp var_hash
    #puts "****"

    while(true)
      rc = new_restrict.gsub!(/#{var_expr}/) { | var |
        new_term = var_hash[var]
        case new_term
        when /^#{deny_expr}$/
          new_term = "(not " + new_term[1..-1] + ")"
        when /^#{prod_expr}$/
          new_term = "(and " + new_term.split("*").join(" ") + ")"
        when /^#{sum_expr}$/
          new_term = "(or " + new_term.split("+").join(" ") + ")"
        else
          # その他は変換無し
        end
        new_term
      }
      break unless(rc)
    end
    new_restrict.gsub!(/#{item_expr}/) { | item |
      convert_item(item)
    }
    # pp new_restrict
    new_restrict
  end

  # CITの文法に変換（＝＝）
  def convert_item(item)
    "(== [" + item.split("_")[0] + "] " + item + ")"
  end

  # CITの文法に変換（＜＞）
  def convert_false_item(item)
    "(<> [" + item.split("_")[0] + "] " + item + ")"
  end

  # ベースとなるテストの入力
  def set_base_tests(params, base_tests)
    if(base_tests)
      sorted_param_keys =  params.keys.sort  # ヘッダとなるパラメタのキー
      result = sorted_param_keys.join(",") + "\n"

      # ベースとなるテストで今回のパラメタに含まれていないものは" "にする。
      base_tests.split("+").each do | base_test |
        base_params = base_test.split("*")
        result_params = []
        sorted_param_keys.each do | param_key |
          param_body = params[param_key] & base_params
          if(param_body.size > 0)
            result_params.push param_body
          else
            # 使用では""でも良いことになっているが、" "でないと通らない
            result_params.push " "
          end
        end
        result += result_params.join(",") + "\n"
      end
    else
      result = nil
    end
    result
  end
end
