import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CurrentNodeCardData {
  const CurrentNodeCardData({required this.groupName, required this.nodeName});

  final String groupName;
  final String nodeName;
}

class CurrentNode extends ConsumerWidget {
  const CurrentNode({super.key});

  static CurrentNodeCardData resolveCardData(WidgetRef ref) {
    final firstGroup = ref.watch(
      currentGroupsStateProvider.select(
        (state) => state.value.isNotEmpty ? state.value.first : null,
      ),
    );
    if (firstGroup == null) {
      return const CurrentNodeCardData(groupName: '-', nodeName: '-');
    }
    final selectedProxyName = ref.watch(
      getSelectedProxyNameProvider(firstGroup.name),
    );
    if (selectedProxyName == null || selectedProxyName.isEmpty) {
      return CurrentNodeCardData(groupName: firstGroup.name, nodeName: '-');
    }
    final realSelectedState = ref.watch(
      realSelectedProxyStateProvider(selectedProxyName),
    );
    final realProxyName = realSelectedState.proxyName;
    final displayName =
        realProxyName.isNotEmpty && realProxyName != selectedProxyName
        ? '$selectedProxyName -> $realProxyName'
        : selectedProxyName;
    return CurrentNodeCardData(
      groupName: firstGroup.name,
      nodeName: displayName,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardData = resolveCardData(ref);
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        info: Info(label: cardData.groupName, iconData: Icons.route),
        onPressed: () {},
        child: Container(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                height: globalState.measure.bodyMediumHeight + 2,
                child: FadeThroughBox(
                  child: TooltipText(
                    text: Text(
                      cardData.nodeName,
                      style: context.textTheme.bodyMedium?.toLight.adjustSize(
                        1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
