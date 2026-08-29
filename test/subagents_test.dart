import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_loop.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/subagents.dart';
import 'package:mobile_agent/domain/models.dart';

void main() {
  test('subagent settings round-trip and clamp configured limits', () {
    final settings = SubagentSettings.fromJson(
      '{"provider_id":" provider-two ","model":" gpt-child ","reasoning_effort":"high",'
      '"max_concurrent_threads":99,"max_recursion_depth":0}',
    );

    expect(settings.providerId, 'provider-two');
    expect(settings.model, 'gpt-child');
    expect(settings.reasoningEffort, 'high');
    expect(settings.maxConcurrentThreads, 16);
    expect(settings.maxRecursionDepth, 1);
    expect(
      SubagentSettings.fromJson(settings.toJson()).toMap(),
      settings.toMap(),
    );
  });

  test('subagent tree shares concurrency and recursion limits', () async {
    final runs = <String, Completer<AgentResult>>{};
    final tree = SubagentTree(
      rootTaskId: 'root',
      settings: const SubagentSettings(
        providerId: 'provider-two',
        maxConcurrentThreads: 1,
        maxRecursionDepth: 1,
      ),
      prepare: (_, {required followup}) async {},
      start: (node, _) {
        final run = Completer<AgentResult>();
        runs[node.id] = run;
        return run.future;
      },
      onEvent: (_, _, _) async {},
      interrupt: (node) async {
        runs[node.id]?.complete(
          const AgentResult(status: 'cancelled', messages: []),
        );
      },
    );
    final spawn = _tool(tree, 'spawn_agent');

    final first = await spawn.call({'task_name': 'one', 'message': 'first'});
    expect(first, isA<Map<String, Object?>>());
    expect((first as Map<String, Object?>)['provider_id'], 'provider-two');
    await expectLater(
      spawn.call({'task_name': 'two', 'message': 'second'}),
      throwsStateError,
    );

    final childId = (first)['agent_id'] as String;
    final childSpawn = _tool(tree, 'spawn_agent', parentId: childId);
    await expectLater(
      childSpawn.call({'task_name': 'nested', 'message': 'nested'}),
      throwsStateError,
    );

    await tree.cancelAll();
    expect(tree.hasActiveAgents, isFalse);
  });

  test(
    'wait returns a short completion summary and followup reuses the node',
    () async {
      final prompts = <String>[];
      final events = <String>[];
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {},
        start: (node, prompt) async {
          prompts.add(prompt);
          return AgentResult(
            status: 'completed',
            messages: const [],
            finalText: prompt == 'first' ? 'short result' : 'followup result',
          );
        },
        onEvent: (_, type, _) async => events.add(type),
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      final wait = _tool(tree, 'wait_agent');
      final followup = _tool(tree, 'followup_task');

      final created = await spawn.call({
        'task_name': 'research',
        'message': 'first',
      });
      final id = (created as Map<String, Object?>)['agent_id'] as String;
      final waited = await wait.call({'target': id});
      final agent =
          ((waited as Map<String, Object?>)['agents'] as List).single
              as Map<String, Object?>;

      expect(agent['status'], 'completed');
      expect(agent['summary'], 'short result');
      expect(agent.containsKey('messages'), isFalse);
      expect(prompts, ['first']);

      await followup.call({'target': id, 'message': 'followup'});
      await wait.call({'target': id});
      expect(prompts, ['first', 'followup']);
      expect(events, contains('subagent.completed'));
    },
  );

  test('interrupt reports interrupted without a completion event', () async {
    final run = Completer<AgentResult>();
    final events = <String>[];
    final tree = SubagentTree(
      rootTaskId: 'root',
      settings: const SubagentSettings(),
      prepare: (_, {required followup}) async {},
      start: (_, _) => run.future,
      onEvent: (_, type, _) async => events.add(type),
      interrupt: (_) async {
        run.complete(const AgentResult(status: 'cancelled', messages: []));
      },
    );
    final spawn = _tool(tree, 'spawn_agent');
    final interrupt = _tool(tree, 'interrupt_agent');

    final created = await spawn.call({'task_name': 'long', 'message': 'run'});
    final id = (created as Map<String, Object?>)['agent_id'] as String;
    final result = await interrupt.call({'target': id});
    await tree.waitForChildren();

    expect((result as Map<String, Object?>)['interrupted'], isTrue);
    expect(events, contains('subagent.interrupted'));
    expect(events, isNot(contains('subagent.completed')));
  });

  test(
    'closing during spawn preparation prevents the child from starting',
    () async {
      final preparation = Completer<void>();
      var starts = 0;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {
          if (!followup) await preparation.future;
        },
        start: (_, _) async {
          starts++;
          return const AgentResult(status: 'completed', messages: []);
        },
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
      );

      final spawn = _tool(
        tree,
        'spawn_agent',
      ).call({'task_name': 'late', 'message': 'should not start'});
      final closing = tree.close();
      preparation.complete();

      await expectLater(spawn, throwsStateError);
      await closing;
      expect(starts, 0);
      expect(tree.isClosed, isTrue);
      expect(tree.hasActiveAgents, isFalse);
    },
  );

  test(
    'wait observes a new follow-up instead of the previous completed turn',
    () async {
      final followupRun = Completer<AgentResult>();
      final followupPrepared = Completer<void>();
      final prompts = <String>[];
      var starts = 0;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {
          if (followup && !followupPrepared.isCompleted) {
            followupPrepared.complete();
          }
        },
        start: (_, prompt) {
          prompts.add(prompt);
          starts++;
          if (starts == 1) {
            return Future.value(
              const AgentResult(
                status: 'completed',
                messages: [],
                finalText: 'first',
              ),
            );
          }
          return followupRun.future;
        },
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      final wait = _tool(tree, 'wait_agent');
      final followup = _tool(tree, 'followup_task');
      final created = await spawn.call({
        'task_name': 'worker',
        'message': 'first',
      });
      final id = (created as Map<String, Object?>)['agent_id'] as String;
      await wait.call({'target': id});

      final followupFuture = followup.call({'target': id, 'message': 'second'});
      await followupPrepared.future;
      var waitCompleted = false;
      final waitFuture = wait.call({'target': id}).then<void>((_) {
        waitCompleted = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(waitCompleted, isFalse);

      followupRun.complete(
        const AgentResult(
          status: 'completed',
          messages: [],
          finalText: 'second result',
        ),
      );
      await followupFuture;
      await waitFuture;
      expect(prompts, ['first', 'second']);
      expect(waitCompleted, isTrue);
    },
  );
}

AgentTool _tool(SubagentTree tree, String name, {String parentId = 'root'}) {
  return tree
      .toolsFor(parentId)
      .firstWhere((tool) => tool.definition.name == name);
}
