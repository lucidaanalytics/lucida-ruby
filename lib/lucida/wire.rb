# frozen_string_literal: true

require "json"
require "securerandom"
require "stringio"
require "zlib"

module Lucida
  # Wire helpers shared by the client mixins: ids, timestamps, gzip encoding, transport result normalising.
  module Wire
    Response = Struct.new(:status, :retry_after, :body, :etag)

    module_function

    def iso(t)
      t = Time.now if t.nil?
      return t if t.is_a?(String)

      t.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    def uuid7
      ms = (Time.now.to_f * 1000).to_i
      b = [ms].pack("Q>")[2, 6].bytes + SecureRandom.random_bytes(10).bytes
      b[6] = 0x70 | (b[6] & 0x0F)
      b[8] = 0x80 | (b[8] & 0x3F)
      h = b.pack("C*").unpack1("H*")
      "#{h[0, 8]}-#{h[8, 4]}-#{h[12, 4]}-#{h[16, 4]}-#{h[20, 12]}"
    end

    # JSON body, gzipped (`?compression=gzip`) from 1 KB.
    def encode(url, payload)
      body = JSON.generate(payload)
      return [url, body] if body.bytesize < 1024

      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(body)
      gz.close
      ["#{url}#{url.include?('?') ? '&' : '?'}compression=gzip", io.string]
    end

    # A transport may return an Integer status, or [status, retry_after, body, etag].
    def response(raw)
      return raw if raw.is_a?(Response)

      a = Array(raw)
      Response.new(a[0].to_i, a[1], a[2], a[3])
    end

    def parse_retry_after(v)
      Float(v).clamp(0.0, 60.0)
    rescue ArgumentError, TypeError
      nil
    end

    def retryable?(status) = [0, 408, 429].include?(status) || status >= 500
  end
end
