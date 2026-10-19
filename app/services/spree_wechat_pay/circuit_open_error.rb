module SpreeWechatPay
  # Raised instead of calling WeChat while its circuit is open: the call would
  # only wait out another timeout to reach the same answer.
  #
  # Inherits from {SpreeWechatPay::ConnectionError} because it carries the same
  # meaning — the outcome is unknown — so every caller that already treats a
  # dropped connection as "ask again later" treats this the same way.
  class CircuitOpenError < ConnectionError
    def initialize(message = 'WeChat Pay has not been answering, so the call was not made')
      super(message)
    end
  end
end
