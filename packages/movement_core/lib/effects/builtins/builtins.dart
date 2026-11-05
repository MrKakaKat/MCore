import 'bend_arc.dart';
import 'corner_pin.dart';
import 'mesh_warp.dart';
import 'origami_fold.dart';
import 'outline.dart';
import 'rotate_3d.dart';
import 'squeeze_axis.dart';

/// registers all built-in geometry effects - call once, before anything
/// resolves an effect by id (createEffectInstance/applyEffectStack).
/// Idempotent (re-registering just overwrites the same map entries), so
/// safe to call multiple times, e.g. once per test file.
void registerBuiltinEffects() {
  registerSqueezeAxis();
  registerBendArc();
  registerCornerPin();
  registerMeshWarp();
  registerRotate3d();
  registerOutline();
  registerOrigamiFold();
}
