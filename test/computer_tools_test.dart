import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/computer_tools.dart';
import 'package:mobile_agent/relay/computer_relay_client.dart';

void main() {
  test('Windows multi-computer tools require an explicit server id', () async {
    final group = ComputerAgentToolsGroup();
    group.setRuntime(
      'computer-a',
      ComputerAgentTools(
        relay: ComputerRelayClient(
          baseUrl: 'http://relay.example',
          apiToken: 'api',
        ),
        deviceId: 'device-a',
      ),
    );
    group.setRuntime(
      'computer-b',
      ComputerAgentTools(
        relay: ComputerRelayClient(
          baseUrl: 'http://relay.example',
          apiToken: 'api',
        ),
        deviceId: 'device-b',
      ),
    );

    final exec = group.tools.firstWhere(
      (tool) => tool.definition.name == 'terminal.exec',
    );
    final properties = exec.definition.parameters['properties'] as Map;
    final serverId = properties['server_id'] as Map;

    expect(exec.definition.parameters['required'], contains('server_id'));
    expect(serverId['enum'], ['computer-a', 'computer-b']);
    expect(group.isClosed, isFalse);

    await group.close();
    expect(group.isClosed, isTrue);
  });
}
