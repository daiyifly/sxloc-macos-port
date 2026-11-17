import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import 'about_page.dart';
import 'app_info.dart';
import 'core_client.dart';
import 'ui.dart';
import 'platform_updates.dart';

Future<void> showDesktopAbout(BuildContext context, CoreClient core) {
  final macOS = Platform.isMacOS;
  return showMacSheet<void>(
    context,
    title: '关于随行定位',
    child: AboutContent(
      version: AppInfo.desktopVersion,
      platform: macOS ? 'macOS 桌面版' : 'Windows 桌面版',
      // macOS builds are distributed as a DMG and updated manually from
      // GitHub Releases; the in-app updater is a Windows-only feature.
      updates: macOS ? null : desktopUpdates(core),
      onOpenLink: (url) async {
        await core.call('openGithub', {'url': url});
      },
    ),
  );
}
