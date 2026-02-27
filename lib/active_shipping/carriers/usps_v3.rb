require 'json'

module ActiveShipping
  class USPSV3 < Carrier
    self.retry_safe = true
    self.ssl_version = :TLSv1_2

    cattr_reader :name
    @@name = 'USPSV3'

    RATE_CARRIER_NAME = 'USPS'
    LIVE_API_BASE_URL = 'https://apis.usps.com/shipments/v3'
    TEST_API_BASE_URL = 'https://apis-tem.usps.com/shipments/v3'
    LIVE_AUTH_BASE_URL = 'https://apis.usps.com'
    TEST_AUTH_BASE_URL = 'https://apis-tem.usps.com'
    LIVE_PRIVATE_API_BASE_URL = 'https://api.private.usps.com/shipments/v3'
    TEST_PRIVATE_API_BASE_URL = 'https://api-tem.private.usps.com/shipments/v3'
    LIVE_PRIVATE_AUTH_BASE_URL = 'https://api.private.usps.com'
    TEST_PRIVATE_AUTH_BASE_URL = 'https://api-tem.private.usps.com'
    OAUTH_TOKEN_PATH = '/oauth2/v3/token'
    SHIPPING_OPTIONS_SEARCH_PATH = '/options/search'
    TOKEN_REFRESH_SKEW_SECONDS = 60
    US_POSSESSIONS = %w(AS FM GU MH MP PW PR VI).freeze

    def requirements
      [:consumer_key, :consumer_secret]
    end

    def find_rates(origin, destination, packages, options = {})
      options = @options.merge(options)

      origin = Location.from(origin)
      destination = Location.from(destination)
      packages = Array(packages)

      payload = build_shipping_options_search_request(origin, destination, packages, options)
      response = post_usps_json(SHIPPING_OPTIONS_SEARCH_PATH, payload, options)

      parse_shipping_options_response(origin, destination, packages, response, options)
    end

    def valid_credentials?
      !!oauth_access_token(@options.merge(test: test_mode?))
    rescue ActiveShipping::Error, ResponseError, StandardError
      false
    end

    def find_tracking_info(_tracking_number, _options = {})
      raise NotImplementedError, 'USPSV3 tracking migration is not implemented yet. Migrate rates first, then map Tracking 3.0.'
    end

    def batch_find_tracking_info(_tracking_infos, _options = {})
      raise NotImplementedError, 'USPSV3 tracking migration is not implemented yet. Migrate rates first, then map Tracking 3.0.'
    end

    protected

    def build_shipping_options_search_request(origin, destination, packages, options = {})
      raise ArgumentError, 'USPSV3 options/search expects one packageDescription per request. Pass a single package.' if packages.size != 1

      domestic = domestic_destination?(destination)

      payload = {
        'originZIPCode' => sanitized_postal_code(origin.postal_code || origin.zip),
        'packageDescription' => package_description_payload(packages.first, options, domestic: domestic),
        'pricingOptions' => [pricing_option_payload(options, domestic: domestic)]
      }

      if domestic
        payload['destinationZIPCode'] = sanitized_postal_code(destination.postal_code || destination.zip)
        payload['destinationEntryFacilityType'] = options[:destination_entry_facility_type] if options[:destination_entry_facility_type]
      else
        payload['destinationCountryCode'] = destination.country_code(:alpha2)
        payload['foreignPostalCode'] = destination.postal_code || destination.zip if (destination.postal_code || destination.zip).present?
      end

      if options[:shipping_filter]
        payload['shippingFilter'] = options[:shipping_filter]
      end

      payload
    end

    def parse_shipping_options_response(origin, destination, packages, response_hash, options = {})
      error_message = response_error_message(response_hash)

      if error_message
        return RateResponse.new(
          false,
          error_message,
          response_hash,
          test: !!options[:test],
          xml: JSON.generate(response_hash),
          request: last_request
        )
      end

      rates = rate_option_nodes(response_hash).filter_map do |context|
        build_rate_estimate_from_option_context(context, origin, destination, packages)
      end

      RateResponse.new(
        true,
        '',
        response_hash,
        rates: rates.sort_by(&:total_price),
        test: !!options[:test],
        xml: JSON.generate(response_hash),
        request: last_request
      )
    end

    def build_rate_estimate_from_option_context(context, origin, destination, packages)
      pricing_option = context[:pricing_option]
      shipping_option = context[:shipping_option]
      rate_option = context[:rate_option]

      mail_class = shipping_option['mailClass'].to_s
      service_name = "USPS #{mail_class.tr('_', ' ').split.map(&:capitalize).join(' ')}".strip
      service_code = mail_class
      total_price = rate_option_total_price_cents(rate_option)
      return nil if total_price.nil?

      delivery_date = rate_option.dig('commitment', 'expectedDeliveryDate') || rate_option.dig('commitment', 'scheduleDeliveryDate')
      currency = 'USD'
      messages = extract_messages(rate_option)
      messages << "priceType=#{pricing_option['priceType']}" if pricing_option['priceType'].present?
      messages.uniq!

      RateEstimate.new(
        origin,
        destination,
        RATE_CARRIER_NAME,
        service_name.to_s.empty? ? service_code : service_name,
        service_code: service_code,
        total_price: total_price,
        packages: packages,
        currency: currency,
        delivery_range: delivery_date ? [delivery_date, delivery_date] : nil,
        charge_items: extract_charge_items(rate_option),
        messages: messages
      )
    end

    def rate_option_nodes(response_hash)
      return [] unless response_hash.is_a?(Hash)

      pricing_options = Array(response_hash['pricingOptions']).select { |x| x.is_a?(Hash) }
      return [] if pricing_options.empty?

      nodes = []
      pricing_options.each do |pricing_option|
        shipping_options = Array(pricing_option['shippingOptions']).select { |x| x.is_a?(Hash) }
        shipping_options.each do |shipping_option|
          rate_options = Array(shipping_option['rateOptions']).select { |x| x.is_a?(Hash) }
          rate_options.each do |rate_option|
            nodes << { pricing_option: pricing_option, shipping_option: shipping_option, rate_option: rate_option }
          end
        end
      end
      nodes
    end

    def response_error_message(response_hash)
      return 'USPS API returned an empty response.' if response_hash.nil?
      return nil unless response_hash.is_a?(Hash)

      nested_string_value(
        response_hash,
        [
          %w[error message],
          %w[error errors 0 detail],
          %w[error errors 0 title],
          %w[error_description],
          %w[message]
        ]
      )
    end

    def post_usps_json(path, payload, options = {})
      body = JSON.generate(payload)
      save_request(body)
      headers = {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{oauth_access_token(options)}"
      }
      raw_response = post_with_fallback(api_urls(path, options), body, headers, 'USPS Shipping Options')

      JSON.parse(raw_response)
    rescue JSON::ParserError => e
      raise ActiveShipping::ResponseContentError.new(e, raw_response)
    end

    def oauth_access_token(options = {})
      if @oauth_access_token && @oauth_access_token_expires_at && Time.now.utc < @oauth_access_token_expires_at
        return @oauth_access_token
      end

      token_response = fetch_oauth_token(options)
      token = token_response['access_token']
      raise ActiveShipping::Error, response_error_message(token_response) || 'USPS OAuth token response did not include access_token.' if token.to_s.empty?

      issued_at = token_response['issued_at'].to_s
      issued_time = issued_at.empty? ? Time.now.utc : Time.at((issued_at.to_i / 1000.0)).utc
      expires_in = token_response['expires_in'].to_i
      expires_in = 300 if expires_in <= 0

      @oauth_access_token = token
      @oauth_access_token_expires_at = issued_time + [expires_in - TOKEN_REFRESH_SKEW_SECONDS, 1].max
      @oauth_access_token
    end

    def fetch_oauth_token(options = {})
      payload = {
        'client_id' => @options[:consumer_key],
        'client_secret' => @options[:consumer_secret],
        'grant_type' => 'client_credentials'
      }
      headers = {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json'
      }
      raw_response = post_with_fallback(auth_urls(OAUTH_TOKEN_PATH, options), JSON.generate(payload), headers, 'USPS OAuth token')

      JSON.parse(raw_response)
    rescue JSON::ParserError => e
      raise ActiveShipping::ResponseContentError.new(e, raw_response)
    end

    def api_urls(path, options = {})
      explicit = options[:api_base_url] || @options[:api_base_url]
      return ["#{explicit}#{path}"] if explicit.present?

      if options[:disable_endpoint_fallback] || @options[:disable_endpoint_fallback]
        ["#{default_api_base_url(options)}#{path}"]
      else
        api_base_urls(options).uniq.map { |base| "#{base}#{path}" }
      end
    end

    def auth_urls(path, options = {})
      explicit = options[:auth_base_url] || @options[:auth_base_url]
      return ["#{explicit}#{path}"] if explicit.present?

      if options[:disable_endpoint_fallback] || @options[:disable_endpoint_fallback]
        ["#{default_auth_base_url(options)}#{path}"]
      else
        auth_base_urls(options).uniq.map { |base| "#{base}#{path}" }
      end
    end

    def default_api_base_url(options = {})
      test = options[:test] || test_mode?
      private_hosts = options[:use_private_usps_urls] || @options[:use_private_usps_urls]
      return test ? TEST_PRIVATE_API_BASE_URL : LIVE_PRIVATE_API_BASE_URL if private_hosts

      test ? TEST_API_BASE_URL : LIVE_API_BASE_URL
    end

    def default_auth_base_url(options = {})
      test = options[:test] || test_mode?
      private_hosts = options[:use_private_usps_urls] || @options[:use_private_usps_urls]
      return test ? TEST_PRIVATE_AUTH_BASE_URL : LIVE_PRIVATE_AUTH_BASE_URL if private_hosts

      test ? TEST_AUTH_BASE_URL : LIVE_AUTH_BASE_URL
    end

    def api_base_urls(options = {})
      test = options[:test] || test_mode?
      if test
        [TEST_API_BASE_URL, TEST_PRIVATE_API_BASE_URL]
      else
        [LIVE_API_BASE_URL, LIVE_PRIVATE_API_BASE_URL]
      end
    end

    def auth_base_urls(options = {})
      test = options[:test] || test_mode?
      if test
        [TEST_AUTH_BASE_URL, TEST_PRIVATE_AUTH_BASE_URL]
      else
        [LIVE_AUTH_BASE_URL, LIVE_PRIVATE_AUTH_BASE_URL]
      end
    end

    def post_with_fallback(urls, body, headers, action_name)
      attempts = []
      last_error = nil

      urls.each do |url|
        begin
          return ssl_post(url, body, headers)
        rescue ActiveUtils::ConnectionError, Timeout::Error, SocketError, SystemCallError => e
          attempts << "#{url} (#{e.class}: #{e.message})"
          last_error = e
        end
      end

      raise ActiveShipping::Error, "#{action_name} failed for all endpoints. Attempts: #{attempts.join(' | ')}" if attempts.any?
      raise last_error if last_error
      raise ActiveShipping::Error, "#{action_name} failed before any request attempts."
    end

    def domestic_destination?(destination)
      code = destination.country_code(:alpha2)
      code.blank? || code == 'US' || US_POSSESSIONS.include?(code)
    end

    def package_description_payload(package, options = {}, domestic: true)
      desc = {
        'mailClass' => resolve_mail_class(options, domestic: domestic),
        'weight' => package.pounds.round(3),
        'length' => package.inches(:length).round(2),
        'height' => package.inches(:height).round(2),
        'width' => package.inches(:width).round(2),
        'hasNonstandardCharacteristics' => package.cylinder? ? true : !!options[:has_nonstandard_characteristics]
      }
      desc['girth'] = package.inches(:girth).round(2) if package.cylinder?
      desc['mailingDate'] = options[:mailing_date].strftime('%Y-%m-%d') if options[:mailing_date].respond_to?(:strftime)
      desc['packageValue'] = (package.value.to_f / 100.0).round(2) if package.value
      desc['extraServices'] = Array(options[:extra_services]).map(&:to_i) if options[:extra_services]
      desc
    end

    def pricing_option_payload(options = {}, domestic: true)
      payload = { 'priceType' => price_type_for(options, domestic: domestic) }
      payment = payment_account_payload(options)
      payload['paymentAccount'] = payment if payment
      payload
    end

    def payment_account_payload(options = {})
      account_type = options[:account_type] || @options[:account_type]
      account_number = options[:account_number] || @options[:account_number]
      crid = options[:crid] || @options[:crid]
      return nil if account_type.blank? || account_number.blank?

      payload = {
        'accountType' => account_type,
        'accountNumber' => account_number
      }
      payload['CRID'] = crid if crid.present?
      payload
    end

    def resolve_mail_class(options = {}, domestic: true)
      explicit = options[:mail_class].to_s.upcase
      return explicit if explicit.present?

      domestic ? 'ALL_OUTBOUND' : 'ALL'
    end

    def price_type_for(options = {}, domestic: true)
      explicit = options[:price_type].to_s.upcase
      return explicit if explicit.present?
      return 'COMMERCIAL' if domestic && (options[:commercial_plus] || options[:commercial_base])
      return 'COMMERCIAL_PLUS' if options[:commercial_plus]
      return 'COMMERCIAL_BASE' if options[:commercial_base]
      'COMMERCIAL'
    end

    def sanitized_postal_code(zip)
      zip.to_s.scan(/\d{5}/).first || zip
    end

    def rate_option_total_price_cents(rate_option)
      direct = first_present(rate_option, [
        ['totalPrice'],
        ['totalBasePrice'],
        ['price'],
        ['amount'],
        ['totalAmount']
      ])
      return Package.cents_from(direct) unless direct.nil?

      rates_total = Array(rate_option['rates']).sum { |rate| Package.cents_from(rate['price']) || 0 }
      extra_total = Array(rate_option['extraServices']).sum { |extra| Package.cents_from(extra['price']) || 0 }
      total = rates_total + extra_total
      total.zero? ? nil : total
    end

    def extract_charge_items(rate_option)
      charges = []

      Array(rate_option['rates']).each do |rate|
        base = Package.cents_from(rate['price'])
        if base
          charges << {
            group: 'rate',
            code: rate['SKU'] || rate['rateIndicator'],
            name: rate['productName'] || rate['description'],
            description: rate['description'],
            amount: base
          }
        end

        Array(rate['fees']).each do |fee|
          amount = Package.cents_from(fee['price'])
          next unless amount
          charges << {
            group: 'fee',
            code: fee['SKU'],
            name: fee['name'],
            description: fee['name'],
            amount: amount
          }
        end
      end

      Array(rate_option['extraServices']).each do |extra|
        amount = Package.cents_from(extra['price'])
        next unless amount
        charges << {
          group: 'extra_service',
          code: extra['extraService'],
          name: extra['name'],
          description: extra['name'],
          amount: amount
        }
      end

      charges
    end

    def extract_messages(rate_option)
      warnings = Array(rate_option['extraServices']).flat_map { |extra| Array(extra['warnings']) }
      warnings.filter_map do |warning|
        next unless warning.is_a?(Hash)
        [warning['warningCode'], warning['warningDescription']].compact.join(': ').presence
      end
    end

    def nested_string_value(hash, key_paths)
      first_present(hash, key_paths).to_s.presence
    end

    def first_present(hash, key_paths)
      Array(key_paths).each do |path|
        keys = Array(path)
        value = keys.reduce(hash) do |memo, key|
          memo.respond_to?(:[]) ? memo[key] : nil
        end
        return value unless value.nil?
      end
      nil
    end
  end
end
