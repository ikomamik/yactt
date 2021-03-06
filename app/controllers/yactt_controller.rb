require "pp"
require "tempfile"

class YacttController < ApplicationController

  def load_pict_param
    puts "PICT"
    @ya_pict_param = params[:ya_paramFile].tempfile.read
    pp @ya_pict_param
  end
  
  def load_results
    pp params
    puts "FOO"
    # exec_cit_bach(params)
    cit_bach(params)
  end
  
  def cit_bach(params)
    # モデルファイルの設定
    fp = Tempfile.open("cit_bach_temp")
    fp.print params["ya_pictParam"]
    fp.flush
    params["ya_model_file"] = fp.path

    # ベーステストのファイルの設定
    if(params["ya_seeding_test"] == "on")
      fp2 = Tempfile.open("cit_bach_temp2")
      fp2.puts params["ya_pictSeedTests"]
      fp2.flush
      params["ya_seed_file"] = fp2.path
    end

    # オプションの変換
    options = convert_params(params)
    Dir.chdir("./yactt") do | yactt_path |
      require_dependency "./yactt.rb"
      begin
        @ya_cit_message = nil
        @ya_cit_results = yactt_lib(options)
      rescue RuntimeError => ex
        @ya_cit_message = ex.message
      end
    end
    
    # 不要になった一時ファイルの削除
    fp.close!
    fp2.close! if(params["ya_seeding_test"] == "on")
  end
  
  def convert_params(post_params)
    params = {}
    post_params.each do | key, value |
      case key
      when "ya_pair_strength"
        value = value.to_i
      when "ya_timeout"
        value = (value.length == 0)?nil:value.to_i
      when "ya_random_seed"
        value = (value.length == 0)?nil:value.to_i
      end
      params[key[3..-1].to_sym] = value
    end
    pp params
    params
  end
  
  def exec_cit_bach(params)
    fp = Tempfile.open("cit_bach_temp")
    fp.print params["ya_pictParam"]
    fp.flush
    path = fp.path
    flags = set_flags(params)
    command = "./yactt #{flags} #{path}"
    puts "cd yactt; #{command}"
    # system("cd yactt; #{command}")
    @ya_cit_results = `cd yactt; #{command} 2>&1`
    fp.close!
  end
  
  def set_flags(params)
    solver_solver = {"CIT-BACH" => "cit", "ACTS" => "acts", "PICT" => "pict"}
    flags = []

    flags.push(set_flag("-o", "ya_pair_strength")) if(params["ya_strength"] != "2")
    flags.push(set_flag("-d", "ya_value_delimiter")) if(params["ya_value_delimiter"] != ",")
    flags.push(set_flag("-a", "ya_alias_delimiter")) if(params["ya_alias_delimiter"] != "|")
    flags.push(set_flag("-n", "ya_negative_prefix")) if(params["ya_negative_prefix"] != "~")
    flags.push("-c") if(params["ya_case_sensitive"] == "on")
    flags.push("-b '#{solver_solver[params["ya_back_end"]]}'")
    flags.push(set_flag("-r", "ya_random_seed")) if(params["ya_seed"] != "")
    flags.push(set_flag("--timeout", "ya_timeout")) if(params["ya_timeout"] != "")

    flags.join(" ")
  end
  
  def set_flag(flag, param)
    new_param = params[param].gsub("'", "\\'")
    flag + ((flag[0..1]=="--")?"=":" ") + "'" + new_param + "'"
  end
end
