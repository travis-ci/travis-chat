require 'travis/sso'
require 'rack/ssl'
require 'sinatra'
require 'slim'
require 'rinku'

class Connection
  attr_reader :user, :streams, :id

  def self.all
    @all ||= []
  end

  def self.each(&block)
    all.each(&block)
  end

  def self.find(args)
    args = { id: args } unless args.is_a? Hash
    all.detect { |c| args.all? { |k,v| c.send(k) == v } }
  end

  def self.new(user)
    find(user: user) or super.tap { |c| all << c }
  end

  def initialize(user)
    @user, @streams, @id = user, [], SecureRandom.hex
  end

  def delete(stream)
    streams.delete(stream)
  end

  def <<(data)
    streams.each do |out|
      out << data
    end
  end

  def active?
    streams.any?
  end
end

use Rack::SSL if production?
helpers Travis::SSO::Helpers

use Travis::SSO, mode: :single_page,
  authenticated?: -> r { Connection.find(r.params['id']) or super(r) }

set(history: [], history_size: 100, count: 0)

helpers do
  attr_reader :connection

  def sse(type, locals = {})
    content = Rinku.auto_link(slim(type, locals: locals))
    payload = [type, content, settings.count]
    settings.count += 1
    settings.history << payload
    settings.history.shift until settings.history.size < settings.history_size
    send_sse(payload)
  end

  def send_sse(payload, to = Connection.all)
    type, content, id = payload
    send_line("event: #{type}", to)
    content.each_line { |l| send_line("data: #{l}", to) }
    send_line "id: #{id}", to
    send_line "", to
  end

  def send_line(data, to)
    line = data.gsub(/\r\n/, '') + "\n"
    Array(to).each { |c| c << line }
  end

  def users
    Connection.all.select(&:active?).map(&:user)
  end
end

before do
  @connection ||= Connection.find(id: params[:id]) if params[:id]
  @connection ||= Connection.new(current_user)
  @current_user = connection.user
end

get '/' do
  slim :index, {}, users: slim(:user_list)
end

get '/stream', provides: 'text/event-stream' do
  stream :keep_open do |out|
    connection.streams << out
    sse(:user_list)

    last_seen = env["HTTP_LAST_EVENT_ID"].to_i
    settings.history.each do |payload|
      send_sse(payload, out) if payload.last > last_seen and payload.first != :user_list
    end

    out.callback do
      connection.delete(out)
      sse(:user_list)
    end
  end
end

post '/' do
  sse(:message, message: params[:msg]) unless params[:msg] =~ /^\s*$/
  204
end
