import '../adapter/euicc_adapter.dart';
import '../models/euicc_profile.dart';
import '../services/vowifi_sim_service.dart';
import 'plugin_base.dart';

/// Reads a plain SIM's identity with the VoWiFi SIM service, so an unsupported
/// card can show its operator. Unlike the VoWiFi plugin itself, this one is
/// present in every build that carries the service.
class VowifiSimProbePlugin extends ProfilePlugin {
  @override
  String get id => 'vowifi_sim_probe';

  @override
  String get name => 'SIM probe';

  @override
  bool isMatch(EuiccProfile profile) => false;

  @override
  Future<SimIdentity?> probeSim(Adapter adapter, Reader reader) async {
    final info = await VowifiSimService().probe(adapter, reader);
    return SimIdentity(
      iccid: info.iccid,
      imsi: info.imsi,
      mncLength: info.mncLength,
      gid1: info.gid1,
      gid2: info.gid2,
    );
  }
}
