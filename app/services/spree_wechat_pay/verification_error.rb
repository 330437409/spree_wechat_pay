module SpreeWechatPay
  # An answer arrived that could not be attributed to WeChat.
  #
  # Callers must treat this exactly as they treat a dropped connection: the
  # request may or may not have taken effect, and nothing in the answer can be
  # believed. It inherits from `ConnectionError` for that reason — every call
  # site that already handles "no trustworthy answer" keeps working, and only a
  # caller that needs to tell an unsigned answer from a missing one rescues this
  # class specifically.
  class VerificationError < ConnectionError; end
end
