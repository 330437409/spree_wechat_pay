module SpreeWechatPay
  # The request may or may not have been received. A timeout, a reset connection
  # or a 5xx answers nothing about what happened, which is the difference that
  # matters: a definite rejection can be acted on, an unknown outcome has to be
  # queried before anything is retried.
  #
  # Inherits from core's connection error so that existing callers — the refund
  # workflow converts it to a gateway error — keep working, while a caller that
  # needs the distinction can rescue this class specifically.
  class ConnectionError < Spree::PaymentConnectionError; end
end
