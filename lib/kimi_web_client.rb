require 'net/http'
require 'json'
require 'uri'
require 'websocket'
require 'socket'
require 'securerandom'
require 'open3'

# Client for Kimi Code CLI Web Interface (local uvicorn on 127.0.0.1:5494)
class KimiWebClient
  attr_reader :host, :port, :token

  def initialize(host: nil, port: nil, token: nil)
    settings   = Setting.plugin_redmine_kimi_agent rescue {}
    @host  = host  || settings['kimi_host']  || '127.0.0.1'
    @port  = (port || settings['kimi_port']  || 5494).to_i
    @token = token || settings['kimi_token'] || ''
  end

  # ─── REST ──────────────────────────────────────────────────────────────────

  def health
    rest_get('/healthz')
  end

  def session_create(work_dir: nil, create_dir: false)
    body = { create_dir: create_dir }
    body[:work_dir] = work_dir if work_dir.present?
    rest_post('/api/sessions/', body)
  end

  def session_get(session_id)
    rest_get("/api/sessions/#{session_id}")
  end

  def session_list
    rest_get('/api/sessions/')
  end

  def session_delete(session_id)
    rest_delete("/api/sessions/#{session_id}")
  end

  # ─── WebSocket prompt (sync, with Open3 python fallback) ──────────────────

  # Yields text chunks as they arrive.
  # Returns final accumulated text.
  def prompt(session_id, text, timeout: 120, &on_chunk)
    ws_prompt_ruby(session_id, text, timeout: timeout, &on_chunk)
  rescue => e
    Rails.logger.warn "[KimiWebClient] Ruby WS failed (#{e.class}: #{e.message}), falling back to Python"
    python_prompt(session_id, text, timeout: timeout, &on_chunk)
  end

  # ─── Ruby WebSocket implementation ────────────────────────────────────────

  private

  def ws_prompt_ruby(session_id, text, timeout:, &on_chunk)
    url = "ws://#{@host}:#{@port}/api/sessions/#{session_id}/stream"
    url += "?token=#{@token}" if @token.present?

    uri       = URI.parse(url)
    handshake = WebSocket::Handshake::Client.new(url: url)
    sock      = TCPSocket.new(uri.host, uri.port)
    sock.write(handshake.to_s)

    until handshake.finished?
      b = sock.read(1)
      raise 'WS connection closed during handshake' if b.nil?
      handshake << b
    end
    raise "WS handshake failed: #{handshake.error}" unless handshake.valid?

    incoming       = WebSocket::Frame::Incoming::Client.new(version: handshake.version)
    history_done   = false
    prompt_sent    = false
    accumulated    = +''
    deadline       = Time.now + timeout

    send_rpc = ->(method, params = nil, id: SecureRandom.uuid) {
      msg = { jsonrpc: '2.0', method: method, id: id }
      msg[:params] = params if params
      frame = WebSocket::Frame::Outgoing::Client.new(
        version: handshake.version, data: JSON.generate(msg), type: :text
      )
      sock.write(frame.to_s)
    }

    loop do
      raise "KimiWebClient timeout (#{timeout}s)" if Time.now > deadline

      raw = sock.read_nonblock(4096) rescue nil
      unless raw
        sleep 0.01
        next
      end

      incoming << raw

      while (msg = incoming.next)
        case msg.type
        when :text
          data   = JSON.parse(msg.data) rescue next
          method = data['method']

          case method
          when 'history_complete'
            history_done = true
            unless prompt_sent
              send_rpc.call('prompt', { user_input: text })
              prompt_sent = true
            end

          when 'session_status'
            state = data.dig('params', 'state')
            if prompt_sent && %w[idle stopped error].include?(state)
              sock.close rescue nil
              return accumulated
            end

          when 'event'
            etype   = data.dig('params', 'type')
            payload = data.dig('params', 'payload') || {}
            if %w[agent_text agent_response].include?(etype)
              chunk = payload['text'].to_s
              unless chunk.empty?
                accumulated << chunk
                on_chunk&.call(chunk)
              end
            end

          when 'request'
            req_id   = data['id']
            req_type = data.dig('params', 'type')
            if req_type == 'ApprovalRequest'
              frame = WebSocket::Frame::Outgoing::Client.new(
                version: handshake.version,
                data: JSON.generate({ jsonrpc: '2.0', id: req_id, result: { approved: true } }),
                type: :text
              )
              sock.write(frame.to_s)
            end
          end

        when :ping
          pong = WebSocket::Frame::Outgoing::Client.new(
            version: handshake.version, type: :pong, data: msg.data
          )
          sock.write(pong.to_s)

        when :close
          return accumulated
        end
      end
    end
  ensure
    sock&.close rescue nil
  end

  def python_prompt(session_id, text, timeout:, &on_chunk)
    script  = Rails.root.join('plugins', 'redmine_kimi_agent', 'lib', 'scripts', 'kimi-web-ws.py').to_s
    script  = File.exist?(script) ? script : 'kimi-web-ws.py'
    env     = {
      'KIMI_WEB_HOST'  => @host,
      'KIMI_WEB_PORT'  => @port.to_s,
      'KIMI_WEB_TOKEN' => @token
    }
    accumulated = +''
    Open3.popen3(env, 'python3', script, 'prompt', session_id, text,
                 '--wait', '--timeout', timeout.to_s) do |_, stdout, stderr, thread|
      stdout.each_line do |line|
        accumulated << line
        on_chunk&.call(line)
      end
      unless thread.value.success?
        raise "Python fallback error: #{stderr.read.strip}"
      end
    end
    accumulated
  end

  def rest_get(path)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(path)
      add_auth(req)
      resp = http.request(req)
      JSON.parse(resp.body)
    end
  end

  def rest_post(path, body = nil)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Post.new(path)
      add_auth(req)
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
      resp = http.request(req)
      JSON.parse(resp.body)
    end
  end

  def rest_delete(path)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Delete.new(path)
      add_auth(req)
      http.request(req).code.to_i
    end
  end

  def add_auth(req)
    req['Authorization'] = "Bearer #{@token}" if @token.present?
  end
end
