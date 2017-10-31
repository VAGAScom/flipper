require 'helper'
require 'rack/test'
require 'active_support/cache'
require 'active_support/cache/memory_store'
require 'flipper/middleware/memoizer'
require 'flipper/adapters/active_support_cache_store'
require 'flipper/adapters/operation_logger'
require 'flipper/adapters/memory'

RSpec.describe Flipper::Middleware::Memoizer do
  include Rack::Test::Methods

  let(:memory_adapter) { Flipper::Adapters::Memory.new }
  let(:adapter)        do
    Flipper::Adapters::OperationLogger.new(memory_adapter)
  end
  let(:flipper) { Flipper.new(adapter) }
  let(:env) { { 'flipper' => flipper } }

  after do
    flipper.adapter.memoize = nil
  end

  it 'raises if initialized with app and flipper instance' do
    expect do
      described_class.new(app, flipper)
    end.to raise_error(/no longer initializes with a flipper/)
  end

  it 'raises if initialized with app and block' do
    block = -> { flipper }
    expect do
      described_class.new(app, block)
    end.to raise_error(/no longer initializes with a flipper/)
  end

  RSpec.shared_examples_for 'flipper middleware' do
    it 'delegates' do
      called = false
      app = lambda do |_env|
        called = true
        [200, {}, nil]
      end
      middleware = described_class.new(app)
      middleware.call(env)
      expect(called).to eq(true)
    end

    it 'disables local cache after body close' do
      app = ->(_env) { [200, {}, []] }
      middleware = described_class.new(app)
      body = middleware.call(env).last

      expect(flipper.adapter.memoizing?).to eq(true)
      body.close
      expect(flipper.adapter.memoizing?).to eq(false)
    end

    it 'clears local cache after body close' do
      app = ->(_env) { [200, {}, []] }
      middleware = described_class.new(app)
      body = middleware.call(env).last

      flipper.adapter.cache['hello'] = 'world'
      body.close
      expect(flipper.adapter.cache).to be_empty
    end

    it 'clears the local cache with a successful request' do
      flipper.adapter.cache['hello'] = 'world'
      get '/', {}, 'flipper' => flipper
      expect(flipper.adapter.cache).to be_empty
    end

    it 'clears the local cache even when the request raises an error' do
      flipper.adapter.cache['hello'] = 'world'
      begin
        get '/fail', {}, 'flipper' => flipper
      rescue
        nil
      end
      expect(flipper.adapter.cache).to be_empty
    end

    it 'caches getting a feature for duration of request' do
      flipper[:stats].enable

      # clear the log of operations
      adapter.reset

      app = lambda do |_env|
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        [200, {}, []]
      end

      middleware = described_class.new(app)
      middleware.call(env)

      expect(adapter.count(:get)).to be(1)
    end
  end

  context 'with preload_all' do
    let(:app) do
      # ensure scoped for builder block, annoying...
      instance = flipper
      middleware = described_class

      Rack::Builder.new do
        use middleware, preload_all: true

        map '/' do
          run ->(_env) { [200, {}, []] }
        end

        map '/fail' do
          run ->(_env) { raise 'FAIL!' }
        end
      end.to_app
    end

    include_examples 'flipper middleware'

    it 'eagerly caches known features for duration of request' do
      flipper[:stats].enable
      flipper[:shiny].enable

      # clear the log of operations
      adapter.reset

      app = lambda do |_env|
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:shiny].enabled?
        flipper[:shiny].enabled?
        [200, {}, []]
      end

      middleware = described_class.new(app, preload_all: true)
      middleware.call(env)

      expect(adapter.operations.size).to be(1)
      expect(adapter.count(:get_all)).to be(1)
    end

    it 'caches unknown features for duration of request' do
      # clear the log of operations
      adapter.reset

      app = lambda do |_env|
        flipper[:other].enabled?
        flipper[:other].enabled?
        [200, {}, []]
      end

      middleware = described_class.new(app, preload_all: true)
      middleware.call(env)

      expect(adapter.count(:get)).to be(1)
      expect(adapter.last(:get).args).to eq([flipper[:other]])
    end
  end

  context 'with preload specific' do
    let(:app) do
      # ensure scoped for builder block, annoying...
      instance = flipper
      middleware = described_class

      Rack::Builder.new do
        use middleware, preload: %i(stats)

        map '/' do
          run ->(_env) { [200, {}, []] }
        end

        map '/fail' do
          run ->(_env) { raise 'FAIL!' }
        end
      end.to_app
    end

    include_examples 'flipper middleware'

    it 'eagerly caches specified features for duration of request' do
      # clear the log of operations
      adapter.reset

      app = lambda do |_env|
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:shiny].enabled?
        flipper[:shiny].enabled?
        [200, {}, []]
      end

      middleware = described_class.new app, preload: %i(stats)
      middleware.call(env)

      expect(adapter.count(:get_multi)).to be(1)
      expect(adapter.last(:get_multi).args).to eq([[flipper[:stats]]])
    end

    it 'caches unknown features for duration of request' do
      # clear the log of operations
      adapter.reset

      app = lambda do |_env|
        flipper[:other].enabled?
        flipper[:other].enabled?
        [200, {}, []]
      end

      middleware = described_class.new app, preload: %i(stats)
      middleware.call(env)

      expect(adapter.count(:get)).to be(1)
      expect(adapter.last(:get).args).to eq([flipper[:other]])
    end
  end

  context 'when an app raises an exception' do
    it 'resets memoize' do
      begin
        app = ->(_env) { raise }
        middleware = described_class.new(app)
        middleware.call(env)
      rescue RuntimeError
        expect(flipper.adapter.memoizing?).to be(false)
      end
    end
  end

  context 'with flipper setup in env' do
    let(:app) do
      # ensure scoped for builder block, annoying...
      instance = flipper
      middleware = described_class

      Rack::Builder.new do
        use middleware

        map '/' do
          run ->(_env) { [200, {}, []] }
        end

        map '/fail' do
          run ->(_env) { raise 'FAIL!' }
        end
      end.to_app
    end

    include_examples 'flipper middleware'
  end

  context 'with Flipper setup in env' do
    it 'caches getting a feature for duration of request' do
      Flipper.configure do |config|
        config.default do
          memory = Flipper::Adapters::Memory.new
          logged_adapter = Flipper::Adapters::OperationLogger.new(memory)
          Flipper.new(logged_adapter)
        end
      end
      Flipper.enable(:stats)
      Flipper.adapter.reset # clear the log of operations

      app = lambda do |_env|
        Flipper.enabled?(:stats)
        Flipper.enabled?(:stats)
        Flipper.enabled?(:stats)
        [200, {}, []]
      end

      middleware = described_class.new(app)
      middleware.call('flipper' => Flipper)

      expect(Flipper.adapter.count(:get)).to be(1)
    end
  end

  context 'defaults to Flipper' do
    it 'caches getting a feature for duration of request' do
      Flipper.configure do |config|
        config.default do
          memory_adapter = Flipper::Adapters::Memory.new
          logged_adapter = Flipper::Adapters::OperationLogger.new(memory_adapter)
          Flipper.new(logged_adapter)
        end
      end
      Flipper.enable(:stats)
      Flipper.adapter.reset # clear the log of operations

      app = lambda do |_env|
        Flipper.enabled?(:stats)
        Flipper.enabled?(:stats)
        Flipper.enabled?(:stats)
        [200, {}, []]
      end

      middleware = described_class.new(app)
      middleware.call({})

      expect(Flipper.adapter.count(:get)).to be(1)
    end
  end

  context 'with preload_all and unless option' do
    let(:app) do
      # ensure scoped for builder block, annoying...
      middleware = described_class

      Rack::Builder.new do
        use middleware, preload_all: true,
                        unless: ->(request) { request.path.start_with?("/assets") }

        map '/' do
          run ->(_env) { [200, {}, []] }
        end

        map '/fail' do
          run ->(_env) { raise 'FAIL!' }
        end
      end.to_app
    end

    it 'does NOT preload_all if request matches unless block' do
      expect(flipper).to receive(:preload_all).never
      get '/assets/foo.png', {}, 'flipper' => flipper
    end

    it 'does preload_all if request does NOT match unless block' do
      expect(flipper).to receive(:preload_all).once
      get '/some/other/path', {}, 'flipper' => flipper
    end
  end

  context 'with preload_all and caching adapter' do
    it 'eagerly caches known features for duration of request' do
      memory = Flipper::Adapters::Memory.new
      logged_memory = Flipper::Adapters::OperationLogger.new(memory)
      cache = ActiveSupport::Cache::MemoryStore.new
      cached = Flipper::Adapters::ActiveSupportCacheStore.new(logged_memory, cache, expires_in: 10)
      logged_cached = Flipper::Adapters::OperationLogger.new(cached)
      memo = {}
      flipper = Flipper.new(logged_cached)
      flipper[:stats].enable
      flipper[:shiny].enable

      # clear the log of operations
      logged_memory.reset
      logged_cached.reset

      app = lambda do |_env|
        flipper[:stats].enabled?
        flipper[:stats].enabled?
        flipper[:shiny].enabled?
        flipper[:shiny].enabled?
        [200, {}, []]
      end

      middleware = described_class.new(app, preload_all: true)

      middleware.call('flipper' => flipper)
      expect(logged_cached.count(:get_all)).to be(1)
      expect(logged_memory.count(:get_all)).to be(1)

      middleware.call('flipper' => flipper)
      expect(logged_cached.count(:get_all)).to be(2)
      expect(logged_memory.count(:get_all)).to be(1)

      middleware.call('flipper' => flipper)
      expect(logged_cached.count(:get_all)).to be(3)
      expect(logged_memory.count(:get_all)).to be(1)
    end
  end
end
