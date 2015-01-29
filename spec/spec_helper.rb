ENV['TUTTER_CONFIG_PATH'] = 'spec/fixtures/tutter.yaml'
require 'tutter'
require 'sinatra'
require 'rack/test'
Tutter.environment = :development
set :run, false
set :raise_errors, true
set :logging, true

def app
  Tutter
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
end
