import 'package:args/args.dart';
import 'package:at_client/at_client.dart';
import 'package:at_onboarding_cli/at_onboarding_cli.dart';
import 'package:at_utils/at_logger.dart';

const namespace = 'medshare';
const rootDomain = 'root.atsign.org';

Future<void> main(List<String> args) async {
  AtSignLogger.root_level = 'warning';

  final parser = ArgParser()
    ..addOption('atsign', abbr: 'a', help: 'atSign to authenticate as')
    ..addOption('keys', abbr: 'k', help: 'path to the .atKeys file');
  final opts = parser.parse(args);

  final atSign = opts['atsign'] as String?;
  final keysPath = opts['keys'] as String?;
  if (atSign == null || keysPath == null) {
    print('usage: dart run bin/auth_test.dart -a @atsign -k path/to/file.atKeys');
    return;
  }

  final preference = AtOnboardingPreference()
    ..namespace = namespace
    ..rootDomain = rootDomain
    ..atKeysFilePath = keysPath
    ..hiveStoragePath = 'storage/$atSign/hive'
    ..commitLogPath = 'storage/$atSign/commitLog'
    ..isLocalStoreRequired = true;

  final onboarding = AtOnboardingServiceImpl(atSign, preference);

  print('Authenticating $atSign ...');
  final ok = await onboarding.authenticate();
  print('authenticate() returned: $ok');

  final atClient = onboarding.atClient;
  print('atClient is ${atClient == null ? 'NULL' : 'ready'} for ${atClient?.getCurrentAtSign()}');

  await onboarding.close();
  print('Done.');
}
