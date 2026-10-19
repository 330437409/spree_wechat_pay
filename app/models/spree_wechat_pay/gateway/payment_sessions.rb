module SpreeWechatPay
  class Gateway < ::Spree::Gateway
    # Payment sessions for WeChat Pay.
    #
    # A WeChat transaction is created under a merchant order number we generate;
    # that number, not WeChat's transaction id, is the session's external id,
    # because it exists from the moment we ask for a transaction and WeChat's
    # only exists once the customer has paid.
    module PaymentSessions
      extend ActiveSupport::Concern

      # WeChat's own default when `time_expire` is omitted, which this gateway
      # sends explicitly instead. The transaction stays payable for the whole
      # window while the customer's launch token does not.
      TRANSACTION_VALIDITY = 7.days
      # `code_url` for Native and `prepay_id` for the WeChat-browser and APP
      # scenes are documented as valid for two hours; H5's URL for five minutes.
      LAUNCH_TOKEN_VALIDITY = 2.hours
      H5_LAUNCH_TOKEN_VALIDITY = 5.minutes
      # WeChat caps `description` at 127 characters.
      DESCRIPTION_LIMIT = 127
      SCENES = MerchantContext::TRANSACTION_PATHS.keys.freeze
      # The scenes this version actually implements. `enabled_scenes` accepts the
      # whole vocabulary so a merchant's configuration survives an upgrade, but
      # enabling one that is not built yet is refused plainly rather than failing
      # somewhere further in, where the cause would be unrecognisable.
      IMPLEMENTED_SCENES = %w[native jsapi mini_program h5 app].freeze
      # Scenes that must name the payer on the order.
      PAYER_IDENTITY_SCENES = %w[jsapi mini_program].freeze

      def payment_session_class
        Spree::PaymentSessions::WechatPay
      end

      # @param order [Spree::Cart, Spree::Order]
      # @param external_data [Hash] `scene` to choose the payment scene, and
      #   whatever that scene needs — `payer_client_ip`, and a WeChat
      #   authorization `code` for the scenes that carry a payer identity
      # @return [Spree::PaymentSessions::WechatPay]
      def create_payment_session(order:, amount: nil, external_data: {})
        scene = resolve_scene(external_data)
        total = amount.presence || order.total_minus_store_credits
        amount_in_cents = Spree::Money::Rounding.to_minor_units(total, order.currency)

        if amount_in_cents.zero?
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.zero_amount')
        end

        # Before the new transaction exists, so a session this cart already has
        # open cannot be left standing beside it.
        replace_open_sessions(order)

        number = MerchantOrderNumber.generate(order)
        expires_at = TRANSACTION_VALIDITY.from_now
        openid = openid_for(scene, external_data)
        # Built once and kept with the session: WeChat refuses a repeat of an
        # `out_trade_no` whose parameters differ, so a re-issue has to send this
        # object back unchanged rather than whatever the later request carries.
        scene_info = scene_info_for(scene, external_data)
        response = place_transaction(
          number: number,
          scene: scene,
          owner: order,
          amount_in_cents: amount_in_cents,
          time_expire: expires_at,
          scene_info: scene_info,
          openid: openid
        )

        payment_session_class.create!(
          owner: order,
          payment_method: self,
          amount: total,
          currency: order.currency,
          status: 'pending',
          external_id: number,
          customer: order.customer,
          expires_at: expires_at,
          external_data: session_data(scene, response, openid: openid, scene_info: scene_info,
                                      redirect_url: redirect_url(external_data))
        )
      end

      # Renews or replaces the transaction behind a session.
      #
      # This is also how a lapsed launch token is refreshed: the storefront asks
      # for the same amount again, and the gateway re-issues under the same
      # merchant order number — WeChat permits that when every parameter is
      # identical — or replaces the transaction when the amount has moved. The
      # storefront has one code path either way.
      #
      # @param payment_session [Spree::PaymentSessions::WechatPay]
      # @return [Spree::PaymentSessions::WechatPay]
      def update_payment_session(payment_session:, amount: nil, external_data: {})
        total = amount.presence || payment_session.amount
        changed = total.to_d != payment_session.amount.to_d
        lapsed = payment_session.payload_expired?

        # Nothing to do: same money, live token. Asking twice must not open a
        # second transaction.
        return payment_session if !changed && !lapsed

        scene = payment_session.scene || resolve_scene(external_data)
        amount_in_cents = Spree::Money::Rounding.to_minor_units(total, payment_session.currency)
        owner = payment_session.owner
        # Exchanged once and handed to both the transaction and the session: a
        # code is single use, so a second exchange of the same one fails — and
        # it would fail after the transaction had already been created.
        openid = openid_for(scene, external_data, fallback: payment_session.openid)
        scene_info = update_scene_info(payment_session, scene, external_data, replaced: changed)

        response = if changed
                     replace_transaction(
                       payment_session, scene, amount_in_cents, owner, openid, scene_info
                     )
                   else
                     reissue_transaction(
                       payment_session, scene, amount_in_cents, owner, openid, scene_info
                     )
                   end

        payment_session.update!(
          amount: total,
          external_data: session_data(scene, response, openid: openid, scene_info: scene_info,
                                      redirect_url: redirect_url(external_data))
        )
        payment_session
      end

      # Closes a session nobody is going to complete, so the QR code or prepay
      # id the customer was handed can no longer take money.
      #
      # A transaction WeChat has already been paid for is a refusal, which core
      # reads as "leave the session alone": the money is real, and settling it
      # belongs to the notification or the next confirm, not here. A WeChat we
      # could not reach raises as itself, so the caller asks again later.
      #
      # @param payment_session [Spree::PaymentSessions::WechatPay]
      # @return [Boolean] whether the session was canceled
      # @raise [Spree::Core::GatewayError] when the transaction has been paid
      def cancel_payment_session(payment_session:)
        close_transaction(payment_session.merchant_order_number)

        payment_session.cancel
      end

      # Confirms the session against WeChat rather than against what the
      # storefront reports, and settles it accordingly.
      #
      # Does NOT complete the order — `Carts::Complete` owns that.
      #
      # @param payment_session [Spree::PaymentSessions::WechatPay]
      # @return [Spree::PaymentSessions::WechatPay]
      def complete_payment_session(payment_session:, params: {})
        transaction = transaction_for(payment_session.merchant_order_number)
        response = transaction.query

        if Transaction.paid?(response)
          settle_paid_session(payment_session, response)
        elsif Transaction.closed?(response)
          payment_session.cancel if payment_session.can_cancel?
        elsif Transaction.paying?(response)
          # The customer is in WeChat's payment sheet right now. Closing would
          # abort the payment being made through the transaction, and the
          # notification that settles it is already on its way — so the confirm
          # is answered with the session still pending, which core's completion
          # accepts, rather than with a failure that is not yet one.
          payment_session
        else
          # Unpaid, and WeChat can still be paid — so it is only a failure once
          # the transaction has been closed and the close has actually succeeded.
          close_then_fail(payment_session, transaction)
        end

        payment_session
      end

      private

      def transaction_for(number)
        Transaction.new(context: merchant_context, client: client, merchant_order_number: number)
      end

      # Places the transaction under `number`. The callers differ only in which
      # number that is and when it lapses.
      #
      # @return [Hash] the scene's response — `code_url` for Native, `prepay_id`
      #   for the rest
      def place_transaction(number:, scene:, owner:, amount_in_cents:, time_expire:, scene_info:, openid:)
        transaction_for(number).create(
          scene: scene,
          payload: transaction_payload(
            scene: scene,
            number: number,
            order: owner,
            amount_in_cents: amount_in_cents,
            time_expire: time_expire,
            scene_info: scene_info,
            openid: openid
          )
        )
      end

      def settle_paid_session(payment_session, response)
        payment_session.process if payment_session.can_process?
        payment_session.record_wechat_response(response)
        payment_session.settle_payment!(captured: true, metadata: payment_metadata(response))
        payment_session.complete unless payment_session.completed?
      end

      def close_then_fail(payment_session, transaction)
        transaction.close
        payment_session.fail if payment_session.can_fail?
      rescue ApiError
        # The close was refused. The usual reason is that the customer paid in
        # the moment between the query and the close, so ask again rather than
        # believing the refusal — this branch settling a payment is the race
        # resolving in the customer's favour, not an error path.
        response = transaction.query
        if Transaction.paid?(response)
          settle_paid_session(payment_session, response)
        else
          raise
        end
      end

      # Closes the transaction behind a session, or explains why it cannot be.
      #
      # @param number [String] our merchant order number
      # @return [void]
      # @raise [Spree::Core::GatewayError] when the transaction has been paid
      def close_transaction(number)
        transaction = transaction_for(number)
        response = transaction.query

        # Paid in the window this close was for. The money is real, and saying
        # so is what stops a caller recording a paid session as canceled.
        if Transaction.paid?(response)
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.session_already_paid')
        end

        # Already closed, or reversed, by WeChat: there is nothing left to
        # close, and asking again is refused.
        return if Transaction.closed?(response)

        transaction.close
      rescue ApiError => error
        # Nothing is left to close: a create whose response was lost, or a
        # transaction WeChat had already closed itself. Either way nothing can
        # be paid through it.
        return if %w[ORDER_NOT_EXIST ORDERCLOSED].include?(error.code)

        # Paid between the query and the close: the same refusal, once.
        if error.code == 'ORDERPAID'
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.session_already_paid')
        end

        raise
      end

      # Closes every session this cart still has open with this gateway, so no
      # earlier attempt's QR code can be paid after checkout has moved on. A
      # cart holds at most one open WeChat transaction at a time (core's
      # V-3726 constraint).
      #
      # Every session is read before any is closed: a session WeChat has already
      # been paid for must be refused before an earlier one is dropped, or the
      # cart would be left with neither.
      def replace_open_sessions(order)
        sessions = order.payment_sessions.where(payment_method: self)

        if sessions.exists?(status: 'completed')
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.payment_in_progress')
        end

        # A failed confirm leaves the transaction payable, so it is closed with
        # the open ones.
        closable = sessions.active.order(:id).to_a + sessions.where(status: 'failed').order(:id).to_a
        return if closable.empty?

        closable.each do |payment_session|
          next unless paid_transaction?(payment_session)
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.payment_in_progress')
        end

        closable.each { |payment_session| cancel_payment_session(payment_session: payment_session) }
      rescue Spree::Core::GatewayError
        # A refusal reaches checkout as itself: it names what to do, and the job
        # that also cancels reads it the same way.
        raise
      rescue ApiError, ConnectionError => error
        # Checkout speaks GatewayError. The unused-session job does not — it
        # retries these, and has to see them unwrapped.
        raise Spree::Core::GatewayError, error.message
      end

      # @param payment_session [Spree::PaymentSessions::WechatPay]
      # @return [Boolean] whether WeChat has taken the money for it
      def paid_transaction?(payment_session)
        Transaction.paid?(transaction_for(payment_session.merchant_order_number).query)
      rescue ApiError => error
        return false if error.code == 'ORDER_NOT_EXIST'

        raise
      end

      def replace_transaction(payment_session, scene, amount_in_cents, owner, openid, scene_info)
        # Refused rather than swallowed when the old transaction has been paid:
        # a replacement under a fresh number would re-point the session away
        # from the number the money is arriving against, and the customer's
        # payment would find no session to settle.
        close_transaction(payment_session.merchant_order_number)

        number = MerchantOrderNumber.generate(owner)
        response = place_transaction(
          number: number,
          scene: scene,
          owner: owner,
          amount_in_cents: amount_in_cents,
          time_expire: transaction_expiry(payment_session),
          scene_info: scene_info,
          openid: openid
        )
        # The session is the same intent; only the transaction under it moved.
        payment_session.external_id = number
        response
      end

      def reissue_transaction(payment_session, scene, amount_in_cents, owner, openid, scene_info)
        place_transaction(
          number: payment_session.merchant_order_number,
          scene: scene,
          owner: owner,
          amount_in_cents: amount_in_cents,
          time_expire: transaction_expiry(payment_session),
          scene_info: scene_info,
          openid: openid
        )
      end

      def resolve_scene(external_data)
        requested = (external_data[:scene].presence || external_data['scene'].presence)&.to_s
        enabled = Array(preferred_enabled_scenes).map(&:to_s).select { |scene| SCENES.include?(scene) }

        if enabled.empty?
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.no_scenes_enabled')
        end

        scene = requested.presence || (enabled.one? ? enabled.first : nil)

        if scene.blank?
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.scene_required')
        end

        # A scene the merchant never switched on is refused rather than
        # substituted: the storefront asked because it could drive that one, and
        # quietly paying by a different route is worse than an error.
        unless enabled.include?(scene)
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.scene_not_enabled', scene: scene)
        end

        unless IMPLEMENTED_SCENES.include?(scene)
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.scene_not_implemented', scene: scene)
        end

        scene
      end

      # Every scene shares this shape; what differs per scene is layered on in
      # the phases that implement them.
      def transaction_payload(scene:, number:, order:, amount_in_cents:, time_expire:, scene_info:, openid: nil)
        payload = {
          'appid' => merchant_context.app_id_for(scene),
          'mchid' => merchant_context.merchant_id,
          'description' => description_for(order),
          'out_trade_no' => number,
          'notify_url' => webhook_url,
          'time_expire' => time_expire.iso8601,
          'amount' => { 'total' => amount_in_cents, 'currency' => 'CNY' }
        }

        # The scenes that know who is paying must name them. A scene that needs
        # an openid and does not get one is refused before the call, because
        # WeChat's own error for it is a bare parameter complaint.
        payload['payer'] = { 'openid' => openid } if openid.present?
        payload['scene_info'] = scene_info if scene_info.present?

        payload
      end

      # The scene object a transaction is placed with: mandatory for H5, which
      # needs the customer's device type and IP, and optional for the rest, which
      # carry the IP alone when it is known.
      #
      # @return [Hash, nil]
      def scene_info_for(scene, external_data)
        if scene == 'h5'
          h5_scene_info(payer_client_ip(external_data), h5_type(external_data))
        elsif payer_client_ip(external_data).present?
          { 'payer_client_ip' => payer_client_ip(external_data) }
        end
      end

      # The scene object a re-issue sends back.
      #
      # A replacement is a new transaction under a fresh number, so it takes
      # this request's — the customer is somewhere new. A re-issue repeats the
      # same `out_trade_no`, which WeChat refuses unless every parameter matches
      # the first request, and the IP in the scene object is the one parameter
      # that moves on its own: a refresh hours later would otherwise send a
      # different one and be rejected.
      #
      # @return [Hash, nil]
      def update_scene_info(payment_session, scene, external_data, replaced:)
        return scene_info_for(scene, external_data) if replaced

        payment_session.scene_info || scene_info_for(scene, external_data)
      end

      # The fields H5 requires, refused here rather than handed to WeChat to
      # reject with a bare parameter complaint.
      def h5_scene_info(payer_client_ip, h5_type)
        if h5_type.blank?
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.h5_type_required')
        end
        if payer_client_ip.blank?
          raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.payer_client_ip_required')
        end

        { 'h5_info' => { 'type' => h5_type }, 'payer_client_ip' => payer_client_ip }
      end

      # What the customer sees on their WeChat bill.
      def description_for(order)
        preferred_statement_descriptor.presence ||
          [store&.name, order.number].compact_blank.join(' ')
            .first(DESCRIPTION_LIMIT)
      end

      def payer_client_ip(external_data)
        external_data[:payer_client_ip].presence || external_data['payer_client_ip'].presence
      end

      def h5_type(external_data)
        external_data[:h5_type].presence || external_data['h5_type'].presence
      end

      def redirect_url(external_data)
        external_data[:redirect_url].presence || external_data['redirect_url'].presence
      end

      # Only what the gateway produced is stored. The caller's own external data
      # is not echoed back: it can carry a single-use authorization code, and the
      # storefront can read this record.
      def session_data(scene, response, openid: nil, redirect_url: nil, scene_info: nil)
        payload = {
          'scene' => scene,
          'payload_expires_at' => (Time.current + launch_token_validity(scene)).iso8601
        }

        payload['code_url'] = response['code_url'] if response['code_url'].present?
        payload['openid'] = openid if openid.present?
        # Kept so a re-issue can send the same one back rather than rebuilding
        # it from a later request.
        payload['scene_info'] = scene_info if scene_info.present?
        payload['h5_url'] = h5_url(response, redirect_url) if response['h5_url'].present?

        if response['prepay_id'].present?
          payload['prepay_id'] = response['prepay_id']
          # Only what the storefront needs to start the payment, signed here.
          # Handing over the raw identifier would leave every storefront
          # implementing the signature, and getting it wrong fails silently.
          payload['launch_params'] = LaunchParameters.new(
            signer: merchant_context.signer,
            scene: scene,
            app_id: merchant_context.app_id_for(scene),
            prepay_id: response['prepay_id']
          ).to_h
        end

        payload
      end

      def launch_token_validity(scene)
        scene == 'h5' ? H5_LAUNCH_TOKEN_VALIDITY : LAUNCH_TOKEN_VALIDITY
      end

      # The URL is passed through untouched except for the URL-encoded return
      # address WeChat redirects to once the customer has paid. WeChat forbids
      # altering it in any other way and rejects a modified one.
      def h5_url(response, redirect_url)
        url = response['h5_url']
        return url if redirect_url.blank?

        "#{url}&redirect_url=#{CGI.escape(redirect_url)}"
      end

      # When the transaction stops being payable.
      #
      # Read from the session rather than computed afresh, because WeChat
      # refuses a repeat of an `out_trade_no` whose parameters differ from the
      # first request, `time_expire` among them — a re-issue with a new instant
      # would be rejected rather than refreshed.
      def transaction_expiry(payment_session)
        payment_session.expires_at || TRANSACTION_VALIDITY.from_now
      end

      # The payer's identity, for the scenes that need one.
      #
      # The authorization code is exchanged here rather than accepted as an
      # openid, because an openid supplied by the browser would be an identity
      # the browser got to choose. The AppSecret also stays here: it is the one
      # credential a storefront must never hold.
      #
      # @param scene [String]
      # @param external_data [Hash] the caller's data, carrying `code`
      # @param fallback [String, nil] an openid already known for this session,
      #   used when the caller sent no new code — a lapsed launch token is
      #   renewed for a payer who never left
      # @return [String, nil] nil for a scene that carries no payer identity
      def openid_for(scene, external_data, fallback: nil)
        return nil unless PAYER_IDENTITY_SCENES.include?(scene.to_s)

        code = external_data[:code].presence || external_data['code'].presence
        return oauth.openid_for(scene: scene, code: code) if code.present?
        return fallback if fallback.present?

        raise Spree::Core::GatewayError,
              I18n.t('spree.wechat_pay.errors.authorization_code_required', scene: scene)
      end

      def oauth
        Oauth.new(context: merchant_context)
      end
    end
  end
end
