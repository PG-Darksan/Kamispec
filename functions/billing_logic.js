"use strict";

function normalizedPlan(value) {
  return value === "max" || value === "pro" ? value : null;
}

function resolveStripePlan(subscription, priceToPlan) {
  const items = subscription && subscription.items &&
    subscription.items.data;
  if (!Array.isArray(items)) return null;

  let resolved = null;
  for (const item of items) {
    const priceId = item && item.price && item.price.id;
    const plan = normalizedPlan(priceId && priceToPlan[priceId]);
    if (plan === "max") return "max";
    if (plan === "pro") resolved = "pro";
  }
  return resolved;
}

function resolveRevenueCatPlan(event, entitlementToPlan, productToPlan) {
  const entitlements = Array.isArray(event && event.entitlement_ids) ?
    event.entitlement_ids :
    (event && event.entitlement_id ? [event.entitlement_id] : []);

  let resolved = null;
  for (const entitlement of entitlements) {
    const plan = normalizedPlan(entitlementToPlan[entitlement]);
    if (plan === "max") return "max";
    if (plan === "pro") resolved = "pro";
  }
  if (resolved != null) return resolved;

  const productId = event && (event.new_product_id || event.product_id);
  return normalizedPlan(productId && productToPlan[productId]);
}

module.exports = {
  resolveRevenueCatPlan,
  resolveStripePlan,
};
