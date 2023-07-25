import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pencil/constants.dart';
import 'package:pencil/data/account/account.dart';
import 'package:pencil/data/task/task.dart';
import 'package:pencil/data/task/tasks_provider.dart';
import 'package:uuid/uuid.dart';

class AccountsProvider extends ChangeNotifier {
  final File _accountsFile;
  late Accounts accounts;

  AccountsProvider() : _accountsFile = File(getPlatformAccountsPath()) {
    _accountsFile.createSync(recursive: true);
    String string = _accountsFile.readAsStringSync();
    accounts = Accounts.fromJson(string.isEmpty ? {} : jsonDecode(string));
  }

  Future<void> removeAccount(String uuid) async {
    accounts.accounts.remove(uuid);
    if (accounts.currentAccount == uuid) {
      if (accounts.accounts.isEmpty) {
        accounts.currentAccount = null;
      } else {
        accounts.currentAccount = accounts.accounts.entries.first.key;
      }
    }
    await save();
  }

  Future<Account?> refreshAccount(Account account, TasksProvider tasks) async {
    if (account.type != AccountType.microsoft || !DateTime.now().isAfter(account.tokenExpireTime!)) {
      return null;
    }
    Task task = Task(name: 'Re-authenticating account ${account.characterName}', type: TaskType.microsoftAuth);
    tasks.addTask(task);
    List<dynamic> tokens = await _refreshMSToken(account.msRefreshToken!, task, tasks);
    String msAccessToken = tokens[0] as String;
    String msRefreshToken = tokens[1] as String;
    int msExpiresIn = tokens[2] as int;
    Account? acc = await _authenticateMicrosoftAccount(msAccessToken, msRefreshToken, msExpiresIn, task, tasks);
    tasks.removeTask(task);
    return acc;
  }

  Future<bool> refreshAccounts(TasksProvider tasks) async {
    List<Account> refreshedAccounts = [];
    bool anyFailures = false;
    for (Account account in accounts.accounts.values) {
      try {
        Account? refreshedAccount = await refreshAccount(account, tasks);
        if (refreshedAccount != null) {
          refreshedAccounts.add(refreshedAccount);
        }
      } catch (e) {
        account.reauthFailed = true;
        anyFailures = true;
      }
    }
    for (Account account in refreshedAccounts) {
      accounts.accounts[account.uuid] = account;
    }
    save();
    return !anyFailures;
  }

  Future<Account> createMicrosoftAccount(BuildContext context, String code, Task task, TasksProvider tasks) async {
    List<dynamic> tokens = await _obtainTokensFromMSCode(code, task, tasks);
    String msAccessToken = tokens[0] as String;
    String msRefreshToken = tokens[1] as String;
    int msExpiresIn = tokens[2] as int;
    Account account = await _authenticateMicrosoftAccount(msAccessToken, msRefreshToken, msExpiresIn, task, tasks);
    if (accounts.accounts.containsKey(account.uuid)) {
      throw Exception('This account has already been added.');
    }
    accounts.accounts[account.uuid] = account;
    accounts.currentAccount = account.uuid;
    await save();
    return account;
  }

  Future<List<dynamic> /* access, refresh, expiresIn */ > _obtainTokensFromMSCode(
      String code, Task task, TasksProvider tasks) async {
    task.currentWork = 'Exchanging authorization code for tokens';
    tasks.notify();
    http.Response codeRp = await http.get(
        Uri.parse(
            'https://login.live.com/oauth20_token.srf?client_id=00000000402B5328&code=$code&redirect_uri=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf&grant_type=authorization_code&scope=service::user.auth.xboxlive.com::MBI_SSL'),
        headers: {'User-Agent': 'XAL Win32 2021.11.20220411.002'});
    if (codeRp.statusCode != 200) {
      throw Exception('Code exchange resulted in ${codeRp.statusCode}');
    }
    Map<String, dynamic> codeRpJ = jsonDecode(utf8.decode(codeRp.bodyBytes));
    if (codeRpJ.containsKey('error')) {
      throw Exception(codeRpJ['error_description']);
    }
    return [codeRpJ['access_token'], codeRpJ['refresh_token'], codeRpJ['expires_in']];
  }

  Future<List<dynamic> /* access, refresh, expiresIn */ > _refreshMSToken(
      String refreshToken, Task task, TasksProvider tasks) async {
    task.currentWork = 'Refreshing access token';
    tasks.notify();
    http.Response tokenRp = await http.get(
        Uri.parse(
            'https://login.live.com/oauth20_token.srf?client_id=00000000402B5328&refresh_token=$refreshToken&grant_type=refresh_token&scope=service::user.auth.xboxlive.com::MBI_SSL'),
        headers: {'User-Agent': 'XAL Win32 2021.11.20220411.002'});
    if (tokenRp.statusCode != 200) {
      throw 2;
    }
    Map<String, dynamic> tokenRpJ = jsonDecode(utf8.decode(tokenRp.bodyBytes));
    if (tokenRpJ.containsKey('error')) {
      throw 2;
    }
    return [tokenRpJ['access_token'], tokenRpJ['refresh_token'], tokenRpJ['expires_in']];
  }

  Future<Account> _authenticateMicrosoftAccount(
      String msAccessToken, String msRefreshToken, int msExpiresIn, Task task, TasksProvider tasks) async {
    DateTime now = DateTime.now();

    task.currentWork = 'Authenticating to Xbox Live';
    tasks.notify();
    http.Response xblRp = await http.post(Uri.parse('https://user.auth.xboxlive.com/user/authenticate'),
        headers: {
          'User-Agent': 'XAL Win32 2021.11.20220411.002',
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: jsonEncode({
          'Properties': {'AuthMethod': 'RPS', 'SiteName': 'user.auth.xboxlive.com', 'RpsTicket': '$msAccessToken'},
          'RelyingParty': 'http://auth.xboxlive.com',
          'TokenType': 'JWT'
        }));
    if (xblRp.statusCode != 200) {
      if (xblRp.statusCode == 400) {
        // Retry with different format, as it is unclear when different formats are required.
        http.Response xblRp = await http.post(Uri.parse('https://user.auth.xboxlive.com/user/authenticate'),
            headers: {
              'User-Agent': 'XAL Win32 2021.11.20220411.002',
              'Content-Type': 'application/json',
              'Accept': 'application/json'
            },
            body: jsonEncode({
              'Properties': {'AuthMethod': 'RPS', 'SiteName': 'user.auth.xboxlive.com', 'RpsTicket': 'd=$msAccessToken'},
              'RelyingParty': 'http://auth.xboxlive.com',
              'TokenType': 'JWT'
            }));
        if (xblRp.statusCode != 200) {
          throw Exception('Xbox Live authentication resulted in ${xblRp.statusCode}');
        }
      } else {
        throw Exception('Xbox Live authentication resulted in ${xblRp.statusCode}');
      }
    }
    Map<String, dynamic> xblRpJ = jsonDecode(utf8.decode(xblRp.bodyBytes));
    String xboxToken = xblRpJ['Token'];
    String xboxUserHash = xblRpJ['DisplayClaims']['xui'][0]['uhs'];

    task.currentWork = 'Authenticating to XSTS';
    tasks.notify();
    http.Response xstsRp = await http.post(Uri.parse('https://xsts.auth.xboxlive.com/xsts/authorize'),
        headers: {
          'User-Agent': 'XAL Win32 2021.11.20220411.002',
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: jsonEncode({
          'Properties': {
            'SandboxId': 'RETAIL',
            'UserTokens': [xboxToken]
          },
          'RelyingParty': 'rp://api.minecraftservices.com/',
          'TokenType': 'JWT'
        }));
    if (xstsRp.statusCode != 200 && xstsRp.statusCode != 401) {
      throw Exception('XSTS authentication resulted in ${xstsRp.statusCode}');
    }
    Map<String, dynamic> xstsRpJ = jsonDecode(utf8.decode(xstsRp.bodyBytes));
    if (xstsRp.statusCode == 401 && xstsRpJ.containsKey('XErr')) {
      switch (xstsRpJ['XErr']) {
        case 2148916233:
          throw Exception('You must create an Xbox account before logging in.');
        case 2148916235:
          throw Exception('Xbox Live is not available in your Microsoft account\'s region.');
        case 2148916236:
        case 2148916237:
          throw Exception('Your Microsoft account needs adult verification. (South Korea)');
        case 2148916238:
          throw Exception('Your Microsoft account must be added to a Family by an adult before continuing.');
        default:
          throw Exception('Unknown Xbox Live error.');
      }
    }
    String xstsToken = xstsRpJ['Token'];

    task.currentWork = 'Fetching Xbox Live profile';
    tasks.notify();
    http.Response xstsProfRp = await http.post(Uri.parse('https://xsts.auth.xboxlive.com/xsts/authorize'),
        headers: {
          'User-Agent': 'XAL Win32 2021.11.20220411.002',
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: jsonEncode({
          'Properties': {
            'OptionalDisplayClaims': ['mgt', 'mgs', 'umg'],
            'SandboxId': 'RETAIL',
            'UserTokens': [xboxToken]
          },
          'RelyingParty': 'http://xboxlive.com',
          'TokenType': 'JWT'
        }));
    if (xstsProfRp.statusCode != 200) {
      throw Exception('Xbox Live profile fetching resulted in ${xstsProfRp.statusCode}');
    }
    Map<String, dynamic> xstsProfRpJ = jsonDecode(utf8.decode(xstsProfRp.bodyBytes));
    String xboxGamertag = xstsProfRpJ['DisplayClaims']['xui'][0]['gtg'];
    String xuid = xstsProfRpJ['DisplayClaims']['xui'][0]['xid'];

    task.currentWork = 'Authenticating to Minecraft Services';
    tasks.notify();
    http.Response minecraftRp = await http.post(Uri.parse('https://api.minecraftservices.com/authentication/login_with_xbox'),
        headers: {'User-Agent': 'XAL Win32 2021.11.20220411.002', 'Content-Type': 'application/json'},
        body: jsonEncode({'identityToken': 'XBL3.0 x=$xboxUserHash;$xstsToken'}));
    if (minecraftRp.statusCode != 200) {
      throw Exception('Minecraft Services authentication resulted in ${xblRp.statusCode}');
    }
    Map<String, dynamic> minecraftRpJ = jsonDecode(utf8.decode(minecraftRp.bodyBytes));
    String mcToken = minecraftRpJ['access_token'];
    int mcExpiresIn = minecraftRpJ['expires_in'];

    task.currentWork = 'Fetching Minecraft profile';
    tasks.notify();
    http.Response profileRp = await http.get(Uri.parse('https://api.minecraftservices.com/minecraft/profile'),
        headers: {'User-Agent': kUserAgent, 'Authorization': 'Bearer $mcToken'});
    if (profileRp.statusCode != 200 && profileRp.statusCode != 404) {
      throw Exception('Minecraft Services profile fetching resulted in ${profileRp.statusCode}');
    }
    Map<String, dynamic> profileRpJ = jsonDecode(utf8.decode(profileRp.bodyBytes));
    if (profileRpJ['error'] == 'NOT_FOUND') {
      throw Exception(
          'You must log in to the official Minecraft Launcher or minecraft.net at least once to set up your Minecraft profile.');
    }
    String username = profileRpJ['name'];
    String unhyphenedUUID = profileRpJ['id'];
    String uuid =
        '${unhyphenedUUID.substring(0, 8)}-${unhyphenedUUID.substring(8, 12)}-${unhyphenedUUID.substring(12, 16)}-${unhyphenedUUID.substring(16, 20)}-${unhyphenedUUID.substring(20, 32)}';

    return Account(username, username, uuid, xuid, xboxGamertag, mcToken, msAccessToken, msRefreshToken, xboxToken, xboxUserHash,
        xstsToken, now.add(Duration(seconds: min(mcExpiresIn, msExpiresIn))), false, AccountType.microsoft);
  }

  Future<Account> createOfflineAccount(BuildContext context, String username, UuidValue uuid) async {
    Account account = Account(username, username, uuid.toString(), null, null, 'pencil-for-minecraft', null, null, null, null,
        null, DateTime(3000), false, AccountType.offline);
    accounts.accounts[uuid.toString()] = account;
    accounts.currentAccount = uuid.toString();
    await save();
    return account;
  }

  Future<void> save() async {
    if (accounts.accounts.isNotEmpty) {
      accounts.currentAccount ??= accounts.accounts.entries.first.key;
    }
    notifyListeners();
    await _accountsFile.writeAsString(jsonEncode(accounts.toJson()));
  }

  static String getPlatformAccountsPath() {
    if (Platform.isLinux) {
      return path.join(Platform.environment['XDG_CONFIG_HOME'] ?? path.join(Platform.environment['HOME']!, '.config'), 'pencil',
          'accounts.json');
    } else if (Platform.isWindows) {
      return path.join(Platform.environment['APPDATA']!, 'Pencil', 'accounts.json');
    } else if (Platform.isMacOS) {
      return path.join(Platform.environment['HOME']!, 'Library', 'Application Support', 'Pencil', 'accounts.json');
    }
    throw Exception('Unsupported Platform');
  }
}
