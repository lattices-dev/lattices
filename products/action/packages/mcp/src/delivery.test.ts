import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { DeliveryError, delivery, withDelivery } from "./delivery.js";

describe("act delivery", () => {
  test("an act that never left Action is safe to resend", () => {
    assert.deepEqual(delivery("not_delivered", "click"), { status: "not_delivered", retrySafe: true, recovery: "retry" });
  });

  test("an uncertain click must be looked at before it is sent again", () => {
    assert.deepEqual(delivery("delivery_uncertain", "click"), {
      status: "delivery_uncertain",
      retrySafe: false,
      recovery: "observe_then_retry",
    });
    assert.equal(delivery("delivery_uncertain", "type").retrySafe, false);
    assert.equal(delivery("delivery_uncertain", undefined).retrySafe, false);
  });

  test("an uncertain focus can be sent again: a second focus is still one focus", () => {
    assert.deepEqual(delivery("delivery_uncertain", "focus-window"), {
      status: "delivery_uncertain",
      retrySafe: true,
      recovery: "retry",
    });
  });

  test("a delivered act is not resent", () => {
    assert.equal(delivery("delivered_unverified", "click").retrySafe, false);
    assert.equal(delivery("delivered_unverified", "click").recovery, "none");
  });

  test("tagging keeps the message and the innermost act's delivery", () => {
    const inner = withDelivery(new Error("press failed"), "delivery_uncertain", "click");
    assert.ok(inner instanceof DeliveryError);
    assert.equal(inner.message, "press failed");
    const outer = withDelivery(inner, "not_delivered", "click");
    assert.equal(outer, inner);
    assert.equal(outer.delivery.status, "delivery_uncertain");
  });
});
