class DeliveryItem {
  const DeliveryItem({
    required this.billNo,
    required this.itemCode,
    required this.itemName,
    required this.unitCode,
    required this.selectedQty,
    required this.deliveredQty,
    required this.remainingQty,
  });

  final String billNo;
  final String itemCode;
  final String itemName;
  final String unitCode;
  final double selectedQty;
  final double deliveredQty;
  final double remainingQty;

  factory DeliveryItem.fromJson(Map<String, dynamic> json) {
    double parseDouble(dynamic value) => double.tryParse('$value') ?? 0;

    return DeliveryItem(
      billNo: (json['bill_no'] ?? '').toString(),
      itemCode: (json['item_code'] ?? '').toString(),
      itemName: (json['item_name'] ?? '').toString(),
      unitCode: (json['unit_code'] ?? '').toString(),
      selectedQty: parseDouble(json['selected_qty']),
      deliveredQty: parseDouble(json['delivered_qty']),
      remainingQty: parseDouble(json['remaining_qty']),
    );
  }
}
