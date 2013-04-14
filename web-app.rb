require 'sinatra'
require 'json'
require 'omniauth'
require 'omniauth-google-oauth2'
require 'yaml'
require 'erubis'
require 'tilt'
require 'sass'
require 'haml'
require 'coffee_script'
require 'active_record'
require 'airbrake'
require 'net/http'
require './get_trace_for.rb'

config_path = File.join(File.dirname(__FILE__), 'config.yaml')
if File.exists?(config_path)
  CONFIG = YAML.load_file(config_path)
  env = ENV['RACK_ENV'] || 'development'
  if env == 'production'
    set :static_cache_control, [:public, :max_age => 300]
    set :sass, { :style => :compressed }
    Airbrake.configure { |config| config.api_key = CONFIG['AIRBRAKE_API_KEY'] }
    nil # unicorn will connect to the database
  else
    set :port, 4001
    set :static_cache_control, [:public, :no_cache]
    set :sass, { :style => :compact }
    ActiveRecord::Base.establish_connection(CONFIG['DATABASE_PARAMS'][env])
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end
else # for Heroku, which doesn't support creating config.yaml
  CONFIG = {}
  missing = []
  %w[GOOGLE_KEY GOOGLE_SECRET COOKIE_SIGNING_SECRET AIRBRAKE_API_KEY].each do
    |key| CONFIG[key] = ENV[key] or missing.push key
  end
  CONFIG['STUDENT_CHECKLIST_HOSTNAME'] = { 'production' => ENV['STUDENT_CHECKLIST_HOSTNAME'] } or missing.push 'STUDENT_CHECKLIST_HOSTNAME'
  if missing.size > 0
    raise "Missing config.yaml and ENV keys #{missing.join(', ')}"
  end

  db = URI.parse(ENV['DATABASE_URL'])
  ActiveRecord::Base.establish_connection({
    :adapter  => db.scheme == 'postgres' ? 'postgresql' : db.scheme,
    :host     => db.host,
    :port     => db.port,
    :username => db.user,
    :password => db.password,
    :database => db.path[1..-1],
    :encoding => 'utf8',
  })
end

set :public_folder, 'public'
set :haml, { :format => :html5, :escape_html => true, :ugly => true }

STUDENT_CHECKLIST_HOSTNAME = CONFIG['STUDENT_CHECKLIST_HOSTNAME'][env]

use Rack::Session::Cookie, {
  :key => 'rack.session',
  :secret => CONFIG['COOKIE_SIGNING_SECRET'],
}

use OmniAuth::Builder do
  provider :google_oauth2, CONFIG['GOOGLE_KEY'], CONFIG['GOOGLE_SECRET'], {
    :scope => 'https://www.googleapis.com/auth/plus.me',
    :access_type => 'online',
  }
end

use Airbrake::Sinatra

class User < ActiveRecord::Base
end

class Save < ActiveRecord::Base
end

class Exercise < ActiveRecord::Base
  if ENV['STUDENT_CHECKLIST_DATABASE_URL'] # Heroku
    db = URI.parse(ENV['STUDENT_CHECKLIST_DATABASE_URL'])
    establish_connection({
      :adapter  => db.scheme == 'postgres' ? 'postgresql' : db.scheme,
      :host     => db.host,
      :port     => db.port,
      :username => db.user,
      :password => db.password,
      :database => db.path[1..-1],
      :encoding => 'utf8',
    })
  else
    establish_connection(CONFIG['DATABASE_PARAMS'][
      "student_checklist_#{ENV['RACK_ENV'] || 'development'}"])
  end
end

def authenticated?
  @current_user =
    User.find_by_google_plus_user_id(session[:google_plus_user_id])
end

def match(path, opts={}, &block)
  get(path, opts, &block)
  post(path, opts, &block)
end

def load_methods
  YAML::load_file('ruby_composer.yaml')
end

def load_word_to_method_indexes(methods)
  word_to_method_indexes = {}
  methods.each_with_index do |method, method_index|
    words = method.values.inject { |a, b| a += " #{b}" }.split(/[^a-z+=_*\/]/).reject { |s| s == '' }.sort.uniq
    words.each { |word|
      if word_to_method_indexes[word].nil?
        word_to_method_indexes[word] = []
      end
      word_to_method_indexes[word].push method_index
    }
  end
  word_to_method_indexes
end

def load_i_have_to_method_indexes(methods)
  word_to_method_indexes = {}
  methods.each_with_index do |method, method_index|
    method['inputs'].split(', ').each do |i_have|
      if word_to_method_indexes[i_have].nil?
        word_to_method_indexes[i_have] = []
      end
      word_to_method_indexes[i_have].push method_index
    end
  end
  word_to_method_indexes
end

def load_i_need_to_method_indexes(methods)
  word_to_method_indexes = {}
  methods.each_with_index do |method, method_index|
    i_need = method['output']
    if word_to_method_indexes[i_need].nil?
      word_to_method_indexes[i_need] = []
    end
    word_to_method_indexes[i_need].push method_index
  end
  word_to_method_indexes
end

helpers do
  def create_javascript_var(var_name, var_value)
    js = "var #{var_name} = {"
    var_value.each do |key, value|
      js += "#{key.inspect}: #{value.inspect},"
    end
    js += "1: 1 };"
    js
  end
end

before do
  if ['/auth/google_oauth2/callback', '/auth/failure', '/login'].include?(request.path_info)
    pass
  elsif !authenticated?
    redirect '/login'
  end
end

get '/' do
  old_record =
    Save.where({
      :user_id      => @current_user.id,
      :task_id      => '/',
      :is_current   => true
    }).first
  @user_code = (old_record || Save.new).code || ''
  @traces = get_trace_for_cases(@user_code, [{}])
  @methods = load_methods
  @word_to_method_indexes = load_word_to_method_indexes(@methods)
  @i_have_to_method_indexes = load_i_have_to_method_indexes(@methods)
  @i_need_to_method_indexes = load_i_need_to_method_indexes(@methods)
  haml :index
end

post '/' do
  if params['logout']
    session[:google_plus_user_id] = nil
    redirect '/'
  end
  @user_code = params['user_code_textarea']
  Save.transaction do
    Save.update_all("is_current = 'f'", {
      :user_id      => @current_user.id,
      :task_id      => '/',
      :is_current   => true
    })
    Save.create({
      :user_id      => @current_user.id,
      :task_id      => '/',
      :is_current   => true,
      :code         => @user_code,
    })
  end
  @traces = get_trace_for_cases(@user_code, [{}])
  @methods = load_methods
  @word_to_method_indexes = load_word_to_method_indexes(@methods)
  @i_have_to_method_indexes = load_i_have_to_method_indexes(@methods)
  @i_need_to_method_indexes = load_i_need_to_method_indexes(@methods)
  haml :index
end

# Example callback:
#
# {"provider"=>"google_oauth2",
#  "uid"=>"112826277336975923063",
#  "info"=>{},
#  "credentials"=>
#   {"token"=>"ya29.AHES6ZRDLUipo8HB5wLy7MoO81vjath9i7Wx-4nI-duhXyE",
#    "expires_at"=>1363146592,
#    "expires"=>true},
#  "extra"=>{"raw_info"=>{"id"=>"112826277336975923063"}}}
#
get '/auth/google_oauth2/callback' do
  response = request.env['omniauth.auth']
  uid = response['uid']
  session[:google_plus_user_id] = uid
  if authenticated?
    redirect "/"
  else
    session[:google_plus_user_id] = nil
    redirect "/auth/failure?message=Sorry,+you're+not+on+the+list.+Contact+dtstutz@gmail.com+to+be+added."
  end
end

get '/auth/failure' do
  @auth_failure_message = params['message']
  haml :login
end

get '/login' do
  haml :login
end

match '/exercise/:task_id' do |task_id|
  if params['logout']
    session[:google_plus_user_id] = nil
    redirect '/'
  end

  exercise = Exercise.find_by_task_id(task_id)
  halt(404, 'Exercise not found') if exercise.nil?
  begin
    @exercise = YAML.load(exercise.yaml)
  rescue Psych::SyntaxError => e
    halt 500, "#{e.class}: #{e} with #{exercise.yaml}"
  end

  if request.get?
    old_record =
      Save.where({
        :user_id     => @current_user.id,
        :task_id     => task_id,
        :is_current  => true
      }).first
    if old_record
      @user_code = old_record.code
    else
      @user_code = @exercise['starting_code'] || ''
    end
  elsif request.post?
    if params['action'] == 'save'
      @user_code = params['user_code_textarea']
      Save.transaction do
        Save.update_all("is_current = 'f'", {
          :user_id      => @current_user.id,
          :task_id      => task_id,
          :is_current   => true
        })
        Save.create({
          :user_id      => @current_user.id,
          :task_id      => task_id,
          :is_current   => true,
          :code         => @user_code,
        })
      end
    elsif params['action'] == 'restore'
      Save.where({
        :user_id      => @current_user.id,
        :task_id      => task_id,
        :is_current   => true
      }).update_all(:is_current => false)
      redirect "/exercise/#{task_id}"
    end
  end

  cases_given =
    (@exercise['cases'] || [{}]).map { |_case| _case['given'] || {} }
  @traces = get_trace_for_cases(@user_code, cases_given)

  num_passed = 0
  num_failed = 0
  @traces.each_with_index do |trace, i|
    passed = nil
    if @exercise['cases'].nil? || @exercise['cases'][i].nil?
      # cases don't apply to this exercise
    elsif expected_return = @exercise['cases'][i]['expected_return']
      passed = (trace['returned'] == expected_return)
    elsif expected_stdout = @exercise['cases'][i]['expected_stdout']
      passed = ((trace['trace'].last['stdout'] || '').chomp == expected_stdout)
    end

    trace['passed'] = passed
    num_passed += 1 if passed == true
    num_failed += 1 if passed == false
  end

  if (task_id[0] == 'C' && num_passed > 0 && num_failed == 0) ||
     (task_id[0] == 'D')
    uri = URI.parse("http://#{STUDENT_CHECKLIST_HOSTNAME}/mark_task_complete")
    data = {
      'google_plus_user_id' => @current_user.google_plus_user_id,
      'task_id'             => task_id,
    }
    begin
      Net::HTTP.post_form(uri, data)
    rescue Errno::ECONNREFUSED => e
      # Heroku apparently doesn't allow this
    end
  end

  @methods = load_methods
  @word_to_method_indexes = load_word_to_method_indexes(@methods)
  @i_have_to_method_indexes = load_i_have_to_method_indexes(@methods)
  @i_need_to_method_indexes = load_i_need_to_method_indexes(@methods)

  haml :index
end

get '/css/application.css' do
  sass 'sass/application'.intern
end

get '/js/application.js' do
  coffee 'coffee/application'.intern
end

after do
  ActiveRecord::Base.clear_active_connections!
end
