"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  resolveRevenueCatPlan,
  resolveStripePlan,
} = require("../billing_logic");

test("unknown Stripe prices fail closed", () => {
  const subscription = {
    items: {data: [{price: {id: "price_unrelated"}}]},
  };
  assert.equal(resolveStripePlan(subscription, {price_pro: "pro"}), null);
});

test("Stripe max wins even when it is not the first item", () => {
  const subscription = {
    items: {data: [
      {price: {id: "price_pro"}},
      {price: {id: "price_max"}},
    ]},
  };
  assert.equal(resolveStripePlan(subscription, {
    price_pro: "pro",
    price_max: "max",
  }), "max");
});

test("unknown RevenueCat products fail closed", () => {
  assert.equal(resolveRevenueCatPlan(
      {product_id: "unrelated_product"},
      {pro: "pro", max: "max"},
      {pro_monthly: "pro"}), null);
});

test("RevenueCat max entitlement wins regardless of event order", () => {
  assert.equal(resolveRevenueCatPlan(
      {entitlement_ids: ["pro", "max"]},
      {pro: "pro", max: "max"},
      {}), "max");
});
