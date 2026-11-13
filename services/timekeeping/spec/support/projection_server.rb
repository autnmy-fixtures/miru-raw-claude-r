# frozen_string_literal: true

require "puma"

# A stand-in for the existing application's projection endpoint
# (entry_snapshot.json deliver_snapshots), served over real HTTP on a free
# local port, so the relay's specs exercise the call it makes in the local
# demo. It records every request and answers what its responder returns; by
# default the contract's receipt, every snapshot applied.
class ProjectionServer
  Request = Data.define(:method, :path, :headers, :body)

  RECEIPT = ->(request) { [200, { "content-type" => "application/json" }, [JSON.generate("applied" => request.body.fetch("snapshots").size, "ignored" => 0)]] }

  attr_reader :requests

  def initialize(&responder)
    @responder = responder || RECEIPT
    @requests = Queue.new
  end

  def start
    @server = Puma::Server.new(method(:call), nil, min_threads: 1, max_threads: 4, log_writer: Puma::LogWriter.null)
    @server.add_tcp_listener("127.0.0.1", 0)
    @server.run
    self
  end

  def stop = @server&.stop(true)

  def url = "http://127.0.0.1:#{@server.connected_ports.first}"

  def received
    [].tap { |all| all << @requests.pop until @requests.empty? }
  end

  def call(env)
    headers = env.select { |name, _| name.start_with?("HTTP_") }
      .transform_keys { |name| name.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-") }
      .merge("Content-Type" => env["CONTENT_TYPE"])
    request = Request.new(method: env["REQUEST_METHOD"], path: env["PATH_INFO"], headers:, body: JSON.parse(env["rack.input"].read))
    @requests << request
    @responder.call(request)
  end
end
