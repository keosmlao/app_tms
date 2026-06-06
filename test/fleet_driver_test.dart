import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/models/fleet_driver.dart';

void main() {
  test('FleetDriver parses a vehicle GPS marker', () {
    final marker = FleetDriver.fromJson({
      'unit_key': 'vehicle:123',
      'source': 'vehicle',
      'car': 'ບລ 2941',
      'lat': '17.9757',
      'lng': '102.6331',
      'speed': 25,
      'address': 'Vientiane',
      'age_seconds': 30,
    });

    expect(marker.isVehicleGps, isTrue);
    expect(marker.isPhoneGps, isFalse);
    expect(marker.hasLocation, isTrue);
    expect(marker.isOnline, isTrue);
    expect(marker.speed, '25');
    expect(marker.address, 'Vientiane');
  });

  test('FleetDriver defaults legacy markers to phone GPS', () {
    final marker = FleetDriver.fromJson({
      'unit_key': 'phone:123',
      'driver': 'Driver',
      'car': 'Truck',
      'lat': 0,
      'lng': 0,
    });

    expect(marker.isPhoneGps, isTrue);
    expect(marker.isVehicleGps, isFalse);
    expect(marker.hasLocation, isFalse);
  });
}
