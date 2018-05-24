require_relative "../../test_helper"

class Test::Proxy::Caching::TestGzip < Minitest::Test
  include ApiUmbrellaTestHelpers::Setup
  include ApiUmbrellaTestHelpers::Caching
  parallelize_me!

  def setup
    super
    setup_server
  end

  def test_caches_gzip_version
    assert_cacheable("/api/cacheable-compressible/", {
      :accept_encoding => "gzip",
    })
  end

  def test_caches_ungzip_version
    assert_cacheable("/api/cacheable-compressible/", {
      :accept_encoding => false,
    })
  end

  # Ideally we would return a cached response regardless of whether the first
  # request was gzipped or not. But for now, we don't support this, and the
  # gzip and non-gzipped versions must be requested and cached separately.
  #
  # Varnish supports this more optimized behavior, but it does so by forcing
  # gzip to always be on, then only caching the gzipped version, and then
  # un-gzipping it on the fly for each non-gzip client. For our API traffic, it
  # seems that gzip being enabled is actually the minority of requests (only
  # 40% based on some current production stats), so forcing each request to be
  # un-gzipped on the fly seems like unnecessary overhead given our current
  # usage.
  #
  # In our explorations of TrafficServer, this is unsupported:
  # http://permalink.gmane.org/gmane.comp.apache.trafficserver.user/4191
  #
  # It's possible we might want to revisit this if we decide saving the backend
  # bandwidth is more efficient than unzipping each request on the fly for each
  # non-gzip client.
  def test_separates_gzip_and_unzip_version
    refute_cacheable("/api/cacheable-compressible/", {
      :accept_encoding => "gzip",
    }, {
      :accept_encoding => false,
    })
  end

  def test_backend_gzips_itself
    # Validate that underlying API is pre-gzipped.
    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip/", http_options.deep_merge(:accept_encoding => "gzip"))
    assert_response_code(200, response)
    assert_equal("gzip", response.headers["content-encoding"])
    data = MultiJson.load(response.body)
    assert_kind_of(Hash, data["headers"])
    assert_equal("gzip", data["headers"]["accept-encoding"])

    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip/", http_options)
    assert_response_code(200, response)
    assert_nil(response.headers["content-encoding"])
    data = MultiJson.load(response.body)
    assert_kind_of(Hash, data["headers"])
    assert_nil(data["headers"]["accept-encoding"])

    assert_gzip("/api/cacheable-pre-gzip/")
  end

  def test_backend_force_gzips_itself
    # Validate that underlying API is pre-gzipped.
    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip/?force=true", http_options.deep_merge(:accept_encoding => "gzip"))
    assert_response_code(200, response)
    assert_equal("gzip", response.headers["content-encoding"])
    data = MultiJson.load(response.body)
    assert_kind_of(Hash, data["headers"])
    assert_equal("gzip", data["headers"]["accept-encoding"])

    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip/?force=true", http_options)
    assert_response_code(200, response)
    assert_equal("gzip", response.headers["content-encoding"])
    data = MultiJson.load(Zlib::GzipReader.new(StringIO.new(response.body)).read)
    assert_kind_of(Hash, data["headers"])
    assert_nil(data["headers"]["accept-encoding"])

    assert_gzip("/api/cacheable-pre-gzip/?force=true")
  end

  def test_backend_does_not_gzip_no_vary
    assert_gzip("/api/cacheable-compressible/")
  end

  def test_backend_does_not_gzip_vary_accept_encoding
    assert_gzip("/api/cacheable-vary-accept-encoding/")
  end

  def test_backend_gzips_itself_multiple_vary
    # Validate that underlying API is pre-gzipped.
    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip-multiple-vary/", http_options)
    assert_response_code(200, response)
    assert_equal("gzip", response.headers["content-encoding"])
    data = MultiJson.load(Zlib::GzipReader.new(StringIO.new(response.body)).read)
    assert_kind_of(Hash, data["headers"])
    assert_nil(data["headers"]["accept-encoding"])

    assert_gzip("/api/cacheable-pre-gzip-multiple-vary/")
  end

  def test_backend_force_gzips_itself_multiple_vary
    # Validate that underlying API is pre-gzipped.
    response = Typhoeus.get("http://127.0.0.1:9444/cacheable-pre-gzip-multiple-vary/?force=true", http_options)
    assert_response_code(200, response)
    assert_equal("gzip", response.headers["content-encoding"])
    data = MultiJson.load(Zlib::GzipReader.new(StringIO.new(response.body)).read)
    assert_kind_of(Hash, data["headers"])
    assert_nil(data["headers"]["accept-encoding"])

    assert_gzip("/api/cacheable-pre-gzip-multiple-vary/?force=true")
  end

  def test_backend_does_not_gzip_multiple_vary
    assert_gzip("/api/cacheable-vary-accept-encoding-multiple/")
  end

  private

  def assert_gzip(path)
    assert_first_request_gzipped_second_request_gzipped(path)
    assert_first_request_gzipped_second_request_not_gzipped(path)
    assert_first_request_not_gzipped_second_request_gzipped(path)
    assert_first_request_not_gzipped_second_request_not_gzipped(path)
  end

  def assert_first_request_gzipped_second_request_gzipped(path)
    first, second = make_duplicate_requests(path, {
      :accept_encoding => "gzip",
    })
    assert_equal("gzip", first.headers["content-encoding"])
    assert_equal("gzip", second.headers["content-encoding"])
  end

  def assert_first_request_gzipped_second_request_not_gzipped(path)
    first, second = make_duplicate_requests(path, {
      :accept_encoding => "gzip",
    }, {
      :accept_encoding => false,
    })
    assert_equal("gzip", first.headers["content-encoding"])
    refute(second.headers["content-encoding"])
  end

  def assert_first_request_not_gzipped_second_request_gzipped(path)
    first, second = make_duplicate_requests(path, {
      :accept_encoding => false,
    }, {
      :accept_encoding => "gzip",
    })
    refute(first.headers["content-encoding"])
    assert_equal("gzip", second.headers["content-encoding"])
  end

  def assert_first_request_not_gzipped_second_request_not_gzipped(path)
    first, second = make_duplicate_requests(path, {
      :accept_encoding => false,
    })
    refute(first.headers["content-encoding"])
    refute(second.headers["content-encoding"])
  end
end
