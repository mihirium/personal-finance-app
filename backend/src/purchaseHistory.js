export function mergeTransactions(existingTransactions = [], syncResult = {}) {
  const byId = new Map(existingTransactions.map((transaction) => [transaction.transaction_id, transaction]));

  for (const transaction of syncResult.added ?? []) {
    byId.set(transaction.transaction_id, transaction);
  }

  for (const transaction of syncResult.modified ?? []) {
    byId.set(transaction.transaction_id, transaction);
  }

  for (const removed of syncResult.removed ?? []) {
    byId.delete(removed.transaction_id);
  }

  return [...byId.values()].sort((left, right) => compareDatesDescending(left.date, right.date));
}

export function groupPurchasesByVendor(transactions = []) {
  const groups = new Map();

  for (const transaction of transactions) {
    if (transaction.pending || Number(transaction.amount) <= 0) {
      continue;
    }

    const vendor = vendorNameFor(transaction);
    const current = groups.get(vendor) ?? {
      vendor,
      transactionCount: 0,
      totalSpend: 0,
      currencyCode: transaction.iso_currency_code ?? "USD",
      transactions: []
    };

    current.transactionCount += 1;
    current.totalSpend = roundMoney(current.totalSpend + Number(transaction.amount));
    current.currencyCode = current.currencyCode ?? transaction.iso_currency_code ?? "USD";
    current.transactions.push(transaction);
    groups.set(vendor, current);
  }

  return [...groups.values()]
    .map((group) => ({
      ...group,
      transactions: group.transactions.sort((left, right) => compareDatesDescending(left.date, right.date))
    }))
    .sort((left, right) => {
      if (right.totalSpend !== left.totalSpend) {
        return right.totalSpend - left.totalSpend;
      }

      return left.vendor.localeCompare(right.vendor);
    });
}

function vendorNameFor(transaction) {
  const merchantName = transaction.merchant_name?.trim();
  if (merchantName) {
    return merchantName;
  }

  const name = transaction.name?.trim();
  return name || "Unknown Vendor";
}

function compareDatesDescending(leftDate, rightDate) {
  return String(rightDate).localeCompare(String(leftDate));
}

function roundMoney(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}
