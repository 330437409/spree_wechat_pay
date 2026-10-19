# spree_wechat_pay

WeChat Pay (微信支付) payment gateway for Spree Commerce, built on the payment
session API.

Optional gem: the `spree` meta gem does not depend on it. Add it to your Gemfile
and configure credentials on the payment method in the admin.

## Installation

```ruby
gem 'spree_wechat_pay'
```

```bash
bundle install
```

There is nothing to generate and no migration to run — the gem ships neither.
Restart the app, then add a payment method under **Settings → Payment methods**
and pick **WeChat Pay**.

## Developing

```bash
bundle install
bundle exec rake test_app    # builds the dummy app, once
bundle exec rspec
```

Inside the Spree monorepo, `pnpm test:rspec wechat_pay` runs the same suite through
the shared test harness. Nothing in it talks to WeChat: signatures are proved
with a locally generated key pair and the HTTP layer is stubbed, so it runs
offline.

The gem ships factories for host apps and other extensions:

```ruby
require 'spree_wechat_pay/factories'

gateway = create(:wechat_pay_gateway, store: store)
session = create(:wechat_pay_payment_session)
```

## Extension boundary

This gem is a standalone extension. It ships no migrations, adds one gateway
class (subclassed from `Spree::Gateway`), and patches no Spree model. Its only
runtime dependency beyond `spree_core` is `faraday`, so an update to Spree does
not overwrite it.

Refunds work the way they do in `spree_stripe`: WeChat is asked to return the
money, and its answer settles the refund in Spree. WeChat keeps settling a
refund after accepting it, so the refund carries WeChat's own refund id and
status for an operator to check, and a refund WeChat closes instead of paying
out is refused rather than recorded as money that went back.

## What it supports

Five payment scenes, sharing one gateway record:

| Scene | Where the customer pays | Needs the payer's openid |
| --- | --- | --- |
| JSAPI | Inside the WeChat browser | yes |
| Mini program | Inside a mini program | yes |
| Native | Scans a QR code | no |
| H5 | Mobile browser outside WeChat | no |
| APP | Your own native app | no |

WeChat Pay is one merchant account with several products switched on, so a single
payment method serves whichever scenes you enable.

## One open transaction per cart

WeChat cannot amend a transaction, and it will only re-issue one under the same
merchant order number if every parameter is identical. A cart therefore holds at
most one open WeChat transaction: asking for a session closes whatever that cart
already had open, and each transaction is told when it stops being payable rather
than being left on WeChat's own week-long default. Sessions a buyer left behind
are closed when the order is placed.

A transaction WeChat has already been paid for is never closed and never
replaced. Asking for a session on a cart that has paid, or moving the amount of
one, is refused with a message saying so — the money is real, and it is recorded
when WeChat reports the payment.

Confirming behaves the same way. A customer who confirms while WeChat has their
payment in flight is answered with the session still open rather than failed,
because the money is already moving and the notification settles it a moment
later. One who confirms without having paid has the transaction closed, so the
same QR code cannot be paid afterwards.

## Limitations worth knowing before you choose it

- **Chinese yuan only.** WeChat Pay's domestic API settles in CNY, so the payment
  method only appears for orders in that currency.
- **Charged at checkout.** WeChat offers no general authorize-then-capture split,
  so a store or payment method set to authorize at checkout and capture later
  cannot use this gateway. It is refused when you save the configuration rather
  than when the first order ships.
- **A refund reads as done once WeChat accepts it.** WeChat goes on settling it
  afterwards and Spree is not told when the money lands, so checking a refund
  that is still in flight is a look at the merchant platform — the same position
  Stripe stores are in. What WeChat said, and the refund's own id there, are kept
  on the refund so that check is possible.
- **No stored payment instruments.** WeChat issues no reusable token for one-off
  payments, so customers pay each time. Entrusted deduction (委托代扣) is a
  separate product with its own onboarding.

## Credentials

Set these on the payment method. Secrets are masked on read, but
`spree_payment_methods.preferences` is not encrypted at rest — treat database
dumps accordingly.

| Setting | Notes |
| --- | --- |
| Merchant number | 商户号 |
| Merchant certificate private key | The full PEM block |
| Merchant certificate serial | Shown beside the certificate in the merchant platform |
| APIv3 key | Needed to read every notification WeChat sends; without it, notifications are not sent at all |
| Verification mode | WeChat Pay public key (recommended, never expires) or platform certificates |
| Public key and key id | Public key mode only |
| Application IDs | One per scene you enable: official account, mini program, mobile app |
| Enabled scenes | Which of the five you accept |

Saving credentials runs one authenticated call, so a mismatched certificate and
merchant number are reported immediately. A method whose credentials are half
filled in is refused while you save it, naming what is still missing; a method
with nothing filled in yet is left alone as a draft.

That call is made only when the credentials themselves change — renaming a
method, reordering it, or switching it off never reaches WeChat, so an outage
cannot leave a payment method unsavable.

Which call it is depends on the verification mode. With platform certificates it
is the certificate download, which also proves the APIv3 key, since the
certificates arrive encrypted with it. With the WeChat Pay public key there is
nothing encrypted to read, so the key is first exercised by a real payment
notification. Neither mode can prove WeChat can reach your callback address —
that needs a publicly reachable URL.

### Staying on platform certificates? Schedule the refresh

Platform certificates rotate; WeChat serves the old one beside the new for a
day. Schedule the refresh so the rotation is picked up well inside that overlap
— a gem cannot add to a host's `config/recurring.yml`, so the entry is yours:

```yaml config/recurring.yml
production:
  refresh_wechat_pay_certificates:
    class: SpreeWechatPay::RefreshCertificatesJob
    schedule: at 4am every day
```

A store on the WeChat Pay public key can leave it out — that key never expires
and there is nothing to re-download.

The job is a safety net rather than a requirement. A notification that arrives
with nothing cached has the cache filled for it, inside the five seconds WeChat
waits for an answer, so a store that never schedules this keeps working and pays
one certificate download on the first notification after a cache reset.

## Payment notifications

WeChat sends notifications to
`<your store URL>/api/v3/webhooks/payments/<payment method id>`, which Spree
serves. The URL must be HTTPS, publicly reachable, and carry no query parameters.
WeChat requires an answer within five seconds; Spree verifies the signature
synchronously and does the rest in the background.

Signatures are checked in both directions. A notification that cannot be
verified is refused, and a notification dated more than five minutes from now is
refused as well — WeChat's own rule, and the only thing that stops a captured
notification from being replayed. Answers from WeChat are verified the same way
before anything in them is believed.

Refund notifications arrive at the same address and are acknowledged without
being acted on. A refund's outcome is read from WeChat's answer when it was
asked for, not from a notification that follows it.

## When WeChat is unavailable

Calls are made with short timeouts, and a read that fails is retried twice with
a growing wait between attempts. A call that creates a payment or a refund is
never retried automatically — an unanswered one may have been accepted, so an
unanswered payment is looked up under its merchant number rather than created a
second time.

After repeated failures against one merchant account, further calls to that
account are refused without being made for a minute, after which one call is let
through to see whether WeChat has recovered. This keeps an outage costing one
timeout per worker rather than one per request. The certificate sweep stops when
it meets a refusal instead of failing once per gateway, and picks up on its next
run.

## Further reading

- Source: <https://github.com/330437409/spree_wechat_pay>
- WeChat Pay API documentation: <https://pay.weixin.qq.com/doc/v3/merchant/4012062524>
