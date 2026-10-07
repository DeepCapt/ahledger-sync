/**
 * Auction listing normalization and per-item price summarization.
 *
 * Input listings carry a unit price in copper and a quantity. Percentiles are quantity-weighted
 * so that a stack of 20 at 5g counts as twenty units at 5g, not one observation. That is the
 * number a buyer actually faces: what the Nth cheapest unit costs.
 *
 * Bid-only listings (buyout 0) are excluded entirely: every field in a snapshot describes buyouts.
 */

export interface Listing {
  /** Per-unit buyout in copper. */
  unitPrice: number;
  /** Units in the listing. */
  quantity: number;
}

export interface PriceSummary {
  minBuyout: number;
  medianBuyout: number;
  p25: number;
  p75: number;
  /** Total units across buyout listings. */
  quantity: number;
  /** Number of buyout listings. */
  numAuctions: number;
}

/** One entry in the Blizzard Classic auctions document (`/auctions/{auctionHouseId}`). */
export interface BlizzardClassicAuction {
  id: number;
  item: { id: number; [k: string]: unknown };
  bid?: number;
  buyout?: number;
  quantity: number;
  time_left?: string;
}

/** One entry in a retail-style commodities document; kept for a future Forever namespace. */
export interface BlizzardCommodityAuction {
  id: number;
  item: { id: number };
  unit_price: number;
  quantity: number;
  time_left?: string;
}

export type BlizzardAuction = BlizzardClassicAuction | BlizzardCommodityAuction;

function isCommodity(a: BlizzardAuction): a is BlizzardCommodityAuction {
  return typeof (a as BlizzardCommodityAuction).unit_price === 'number';
}

/**
 * Group raw Blizzard auctions by item id into unit-priced buyout listings.
 * Listings without a positive buyout or quantity are dropped.
 */
export function groupBlizzardAuctions(
  auctions: readonly BlizzardAuction[],
): Map<number, Listing[]> {
  const byItem = new Map<number, Listing[]>();
  for (const a of auctions) {
    const quantity = a.quantity;
    if (!(quantity > 0)) continue;
    let unitPrice = 0;
    if (isCommodity(a)) {
      unitPrice = a.unit_price;
    } else if (a.buyout != null && a.buyout > 0) {
      // A stack listed below 1c per unit still exists; floor at 1c rather than dropping it.
      unitPrice = Math.max(1, Math.round(a.buyout / quantity));
    }
    if (!(unitPrice > 0)) continue;
    const itemId = a.item?.id;
    if (!Number.isInteger(itemId)) continue;
    let list = byItem.get(itemId);
    if (!list) {
      list = [];
      byItem.set(itemId, list);
    }
    list.push({ unitPrice, quantity });
  }
  return byItem;
}

/** Quantity-weighted percentile (nearest-rank over units) of listings sorted by unit price. */
function weightedPercentile(sorted: readonly Listing[], totalQty: number, p: number): number {
  const target = Math.max(1, Math.ceil(totalQty * p));
  let cumulative = 0;
  for (const l of sorted) {
    cumulative += l.quantity;
    if (cumulative >= target) return l.unitPrice;
  }
  return sorted[sorted.length - 1]!.unitPrice;
}

/** Summarize one item's buyout listings. Returns null when there is nothing to summarize. */
export function summarizeListings(listings: readonly Listing[]): PriceSummary | null {
  const valid = listings.filter((l) => l.unitPrice > 0 && l.quantity > 0);
  if (valid.length === 0) return null;
  const sorted = [...valid].sort((a, b) => a.unitPrice - b.unitPrice);
  const quantity = sorted.reduce((s, l) => s + l.quantity, 0);
  return {
    minBuyout: sorted[0]!.unitPrice,
    p25: weightedPercentile(sorted, quantity, 0.25),
    medianBuyout: weightedPercentile(sorted, quantity, 0.5),
    p75: weightedPercentile(sorted, quantity, 0.75),
    quantity,
    numAuctions: sorted.length,
  };
}

/** Summarize a whole auction house document into per-item summaries keyed by Blizzard item id. */
export function summarizeBlizzardAuctions(
  auctions: readonly BlizzardAuction[],
): Map<number, PriceSummary> {
  const out = new Map<number, PriceSummary>();
  for (const [itemId, listings] of groupBlizzardAuctions(auctions)) {
    const summary = summarizeListings(listings);
    if (summary) out.set(itemId, summary);
  }
  return out;
}
