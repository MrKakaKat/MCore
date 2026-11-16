import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/io/save_load.dart';

void main() {
  test('the project\'s gravity is saved with it', () async {
    final dir = await Directory.systemTemp.createTemp('grav');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/p.json');
    final l = createLayer('rect')
      ..physics.collide = true
      ..physics.falls = true
      ..physics.bounce = 0.5;
    await saveProjectToFile(f, Project(layers: [l], gravity: 2400, gravityAngle: 270), maxFrame: 100, playbackSpeed: 1);
    final back = await loadProjectFromFile(f);
    expect(back.project.gravity, 2400);
    expect(back.project.gravityAngle, 270);
    expect(back.project.layers.single.physics.falls, isTrue);
    expect(back.project.layers.single.physics.bounce, 0.5);
  });
}
