import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/dns.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/views/config/scripts.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rules.dart';

class AdvancedConfigView extends StatelessWidget {
  const AdvancedConfigView({super.key});

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    List<Widget> items = [
      ListItem.open(
        title: Text(appLocalizations.network),
        subtitle: Text(appLocalizations.networkDesc),
        leading: const Icon(Icons.vpn_key),
        delegate: OpenDelegate(
          blur: false,
          widget: BaseScaffold(
            title: appLocalizations.network,
            body: const NetworkListView(),
          ),
        ),
      ),
      ListItem.open(
        title: Text('DNS'),
        subtitle: Text(appLocalizations.dnsDesc),
        leading: const Icon(Icons.dns),
        delegate: OpenDelegate(
          widget: BaseScaffold(
            title: 'DNS',
            actions: [
              Consumer(
                builder: (_, ref, _) {
                  return IconButton(
                    onPressed: () async {
                      final res = await globalState.showMessage(
                        title: appLocalizations.reset,
                        message: TextSpan(text: appLocalizations.resetTip),
                      );
                      if (res != true) {
                        return;
                      }
                      ref
                          .read(patchClashConfigProvider.notifier)
                          .update((state) => state.copyWith(dns: defaultDns));
                    },
                    tooltip: appLocalizations.reset,
                    icon: const Icon(Icons.replay),
                  );
                },
              ),
            ],
            body: const DnsListView(),
          ),
          blur: false,
        ),
      ),
      ListItem.open(
        title: Text(appLocalizations.addedRules),
        subtitle: Text(appLocalizations.controlGlobalAddedRules),
        leading: const Icon(Icons.library_books),
        delegate: OpenDelegate(widget: const AddedRulesView(), blur: false),
      ),
      ListItem.open(
        title: Text(appLocalizations.script),
        subtitle: Text(appLocalizations.overrideScript),
        leading: const Icon(Icons.rocket, fontWeight: FontWeight.w900),
        delegate: OpenDelegate(widget: const ScriptsView(), blur: false),
      ),
      if (system.isAndroid)
        ListItem.open(
          title: Text(appLocalizations.networkAutoControl),
          subtitle: Text(appLocalizations.networkAutoControlDesc),
          leading: const Icon(Icons.wifi),
          delegate: OpenDelegate(
            widget: const _NetworkAutoControlView(),
            blur: false,
          ),
        ),
    ];
    return BaseScaffold(
      title: appLocalizations.advancedConfig,
      body: generateListView(
        items.separated(const Divider(height: 0)).toList(),
      ),
    );
  }
}

class _NetworkAutoControlView extends ConsumerWidget {
  const _NetworkAutoControlView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final appSetting = ref.watch(appSettingProvider);

    return BaseScaffold(
      title: appLocalizations.networkAutoControl,
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(appLocalizations.autoStartOnMobileData),
            subtitle: Text(appLocalizations.autoStartOnMobileDataDesc),
            secondary: const Icon(Icons.signal_cellular_alt),
            value: appSetting.autoStartOnMobileData,
            onChanged: (value) {
              ref
                  .read(appSettingProvider.notifier)
                  .update(
                    (state) => state.copyWith(autoStartOnMobileData: value),
                  );
            },
          ),
          const Divider(height: 0),
          SwitchListTile(
            title: Text(appLocalizations.autoStopOnSpecificWifi),
            subtitle: Text(appLocalizations.autoStopOnSpecificWifiDesc),
            secondary: const Icon(Icons.wifi_off),
            value: appSetting.autoStopOnSpecificWifi,
            onChanged: (value) {
              ref
                  .read(appSettingProvider.notifier)
                  .update(
                    (state) => state.copyWith(autoStopOnSpecificWifi: value),
                  );
            },
          ),
          if (appSetting.autoStopOnSpecificWifi) ...[
            const Divider(height: 0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    appLocalizations.autoStopGatewayList,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: appLocalizations.addGatewayAddress,
                    onPressed: () => _showAddGatewayDialog(context, ref),
                  ),
                ],
              ),
            ),
            if (appSetting.autoStopGatewayList.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  appLocalizations.noData,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ...appSetting.autoStopGatewayList.map(
              (ip) => ListTile(
                leading: const Icon(Icons.router),
                title: Text(ip),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    final newList = List<String>.from(
                      appSetting.autoStopGatewayList,
                    )..remove(ip);
                    ref
                        .read(appSettingProvider.notifier)
                        .update(
                          (state) =>
                              state.copyWith(autoStopGatewayList: newList),
                        );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showAddGatewayDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    final appLocalizations = context.appLocalizations;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(appLocalizations.addGatewayAddress),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: appLocalizations.pleaseEnterGatewayAddress,
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(appLocalizations.cancel),
            ),
            TextButton(
              onPressed: () {
                final ip = controller.text.trim();
                if (ip.isNotEmpty) {
                  final currentList = ref
                      .read(appSettingProvider)
                      .autoStopGatewayList;
                  if (!currentList.contains(ip)) {
                    final newList = [...currentList, ip];
                    ref
                        .read(appSettingProvider.notifier)
                        .update(
                          (state) =>
                              state.copyWith(autoStopGatewayList: newList),
                        );
                  }
                }
                Navigator.of(context).pop();
              },
              child: Text(appLocalizations.confirm),
            ),
          ],
        );
      },
    );
  }
}
