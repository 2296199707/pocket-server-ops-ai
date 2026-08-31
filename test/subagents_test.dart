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

  test(
    'wait_agent has bounded timeout and supports immediate polling',
    () async {
      final run = Completer<AgentResult>();
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {},
        start: (_, _) => run.future,
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      final wait = _tool(tree, 'wait_agent');
      final timeoutSchema =
          ((wait.definition.parameters['properties'] as Map)['timeout_ms']
              as Map);

      expect(timeoutSchema['minimum'], 0);
      expect(timeoutSchema['maximum'], 3600000);
      expect(
        timeoutSchema['description'],
        contains('Defaults to 30000; maximum is 3600000'),
      );

      final created = await spawn.call({'task_name': 'long', 'message': 'run'});
      final id = (created as Map<String, Object?>)['agent_id'] as String;
      final result = await wait.call({'target': id, 'timeout_ms': 0});

      expect((result as Map<String, Object?>)['timed_out'], isTrue);
      run.complete(const AgentResult(status: 'completed', messages: []));
      await tree.waitForChildren();
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

  test(
    'a follow-up queued during a running turn starts automatically',
    () async {
      final firstRun = Completer<AgentResult>();
      final secondRun = Completer<AgentResult>();
      final secondStarted = Completer<void>();
      final prompts = <String>[];
      var starts = 0;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {},
        start: (_, prompt) {
          prompts.add(prompt);
          starts++;
          if (starts == 1) return firstRun.future;
          if (!secondStarted.isCompleted) secondStarted.complete();
          return secondRun.future;
        },
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      final followup = _tool(tree, 'followup_task');
      final wait = _tool(tree, 'wait_agent');
      final created = await spawn.call({
        'task_name': 'worker',
        'message': 'first',
      });
      final id = (created as Map<String, Object?>)['agent_id'] as String;

      final queued = await followup.call({'target': id, 'message': 'second'});
      expect((queued as Map<String, Object?>)['queued'], isTrue);
      expect((queued)['starts_turn'], isFalse);

      var waitCompleted = false;
      final waiting = wait.call({'target': id}).then((value) {
        waitCompleted = true;
        return value;
      });
      firstRun.complete(
        const AgentResult(
          status: 'completed',
          messages: [],
          finalText: 'first result',
        ),
      );
      await secondStarted.future;
      expect(waitCompleted, isFalse);

      secondRun.complete(
        const AgentResult(
          status: 'completed',
          messages: [],
          finalText: 'second result',
        ),
      );
      final waited = await waiting;
      final agent =
          ((waited as Map<String, Object?>)['agents'] as List).single
              as Map<String, Object?>;
      expect(prompts, ['first', 'second']);
      expect(agent['status'], 'completed');
      expect(agent['summary'], 'second result');
    },
  );

  test('a queued follow-up survives a failed turn and runs once', () async {
    final firstRun = Completer<AgentResult>();
    final secondRun = Completer<AgentResult>();
    final secondStarted = Completer<void>();
    final events = <String>[];
    var starts = 0;
    final tree = SubagentTree(
      rootTaskId: 'root',
      settings: const SubagentSettings(),
      prepare: (_, {required followup}) async {},
      start: (_, prompt) {
        starts++;
        if (starts == 1) return firstRun.future;
        if (!secondStarted.isCompleted) secondStarted.complete();
        return secondRun.future;
      },
      onEvent: (_, type, _) async => events.add(type),
      interrupt: (_) async {},
    );
    final spawn = _tool(tree, 'spawn_agent');
    final followup = _tool(tree, 'followup_task');
    final wait = _tool(tree, 'wait_agent');
    final created = await spawn.call({
      'task_name': 'worker',
      'message': 'first',
    });
    final id = (created as Map<String, Object?>)['agent_id'] as String;
    await followup.call({'target': id, 'message': 'retry'});

    firstRun.completeError(StateError('temporary failure'));
    await secondStarted.future;
    secondRun.complete(
      const AgentResult(
        status: 'completed',
        messages: [],
        finalText: 'retry result',
      ),
    );

    final waited = await wait.call({'target': id});
    final agent =
        ((waited as Map<String, Object?>)['agents'] as List).single
            as Map<String, Object?>;
    expect(agent['status'], 'completed');
    expect(agent['summary'], 'retry result');
    expect(events, contains('subagent.failed'));
    expect(events.where((type) => type == 'subagent.started'), hasLength(2));
  });

  test(
    'agent targets are scoped by path and cannot interrupt itself',
    () async {
      final runs = <String, Completer<AgentResult>>{};
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(maxRecursionDepth: 2),
        prepare: (_, {required followup}) async {},
        start: (node, _) {
          final run = Completer<AgentResult>();
          runs[node.id] = run;
          return run.future;
        },
        onEvent: (_, _, _) async {},
        interrupt: (node) async {
          final run = runs[node.id];
          if (run != null && !run.isCompleted) {
            run.complete(const AgentResult(status: 'cancelled', messages: []));
          }
        },
      );
      final rootSpawn = _tool(tree, 'spawn_agent');
      final first = await rootSpawn.call({
        'task_name': 'first',
        'message': 'first',
      });
      final firstId = (first as Map<String, Object?>)['agent_id'] as String;
      final second = await rootSpawn.call({
        'task_name': 'second',
        'message': 'second',
      });
      final secondId = (second as Map<String, Object?>)['agent_id'] as String;
      final childSpawn = _tool(tree, 'spawn_agent', parentId: firstId);
      final nested = await childSpawn.call({
        'task_name': 'nested',
        'message': 'nested',
      });
      final nestedId = (nested as Map<String, Object?>)['agent_id'] as String;
      final childList = _tool(tree, 'list_agents', parentId: firstId);
      final visible = await childList.call({});
      final visibleAgents = (visible as Map<String, Object?>)['agents'] as List;

      expect(visibleAgents, hasLength(1));
      expect(
        (visibleAgents.single as Map<String, Object?>)['agent_path'],
        '/root/first/nested',
      );
      final childInterrupt = _tool(tree, 'interrupt_agent', parentId: firstId);
      await expectLater(
        childInterrupt.call({'target': secondId}),
        throwsStateError,
      );
      await expectLater(
        childInterrupt.call({'target': firstId}),
        throwsStateError,
      );

      final rootInterrupt = _tool(tree, 'interrupt_agent');
      final interrupted = await rootInterrupt.call({
        'target': '/root/first/nested',
      });
      expect((interrupted as Map<String, Object?>)['agent_id'], nestedId);
      expect((interrupted)['interrupted'], isTrue);
      await tree.cancelAll();
      expect(tree.hasActiveAgents, isFalse);
    },
  );

  test(
    'failed spawn invokes cleanup for a persisted child reservation',
    () async {
      var discarded = 0;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {
          throw StateError('child setup failed');
        },
        start: (_, _) async =>
            const AgentResult(status: 'completed', messages: []),
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
        discard: (_) async => discarded++,
      );

      await expectLater(
        _tool(
          tree,
          'spawn_agent',
        ).call({'task_name': 'reserved', 'message': 'start'}),
        throwsStateError,
      );
      expect(discarded, 1);
      expect(tree.agents, isEmpty);
    },
  );

  test('close waits for the terminal event sink to settle', () async {
    final run = Completer<AgentResult>();
    final terminalEventStarted = Completer<void>();
    final terminalEvent = Completer<void>();
    final tree = SubagentTree(
      rootTaskId: 'root',
      settings: const SubagentSettings(),
      prepare: (_, {required followup}) async {},
      start: (_, _) => run.future,
      onEvent: (_, type, _) {
        if (type == 'subagent.interrupted') {
          if (!terminalEventStarted.isCompleted) {
            terminalEventStarted.complete();
          }
          return terminalEvent.future;
        }
        return Future<void>.value();
      },
      interrupt: (_) async {
        if (!run.isCompleted) {
          run.complete(const AgentResult(status: 'cancelled', messages: []));
        }
      },
    );
    final created = await _tool(
      tree,
      'spawn_agent',
    ).call({'task_name': 'closing', 'message': 'wait for event'});
    final id = (created as Map<String, Object?>)['agent_id'] as String;

    var closeCompleted = false;
    final closing = tree.close().then<void>((_) {
      closeCompleted = true;
    });
    await terminalEventStarted.future;
    expect(closeCompleted, isFalse);

    terminalEvent.complete();
    await closing;
    expect(tree.nodeFor(id)?.status, 'interrupted');
    expect(tree.hasActiveAgents, isFalse);
  });

  test(
    'close marks an unsettled child unknown instead of waiting forever',
    () async {
      final run = Completer<AgentResult>();
      final interruptNeverSettles = Completer<void>();
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        lifecycleTimeout: const Duration(milliseconds: 20),
        prepare: (_, {required followup}) async {},
        start: (_, _) => run.future,
        onEvent: (_, _, _) async {},
        interrupt: (_) => interruptNeverSettles.future,
      );
      final created = await _tool(
        tree,
        'spawn_agent',
      ).call({'task_name': 'stuck', 'message': 'run'});
      final id = (created as Map<String, Object?>)['agent_id'] as String;

      await tree.close();
      final node = tree.nodeFor(id)!;
      expect(node.status, 'unknown');
      expect(node.summary, contains('远程状态未知'));

      run.complete(const AgentResult(status: 'completed', messages: []));
      await tree.waitForChildren();
      expect(node.status, 'unknown');
    },
  );

  test(
    'follow-up reports interruption when closing before it starts',
    () async {
      final preparationStarted = Completer<void>();
      final preparation = Completer<void>();
      var starts = 0;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {
          if (followup) {
            preparationStarted.complete();
            await preparation.future;
          }
        },
        start: (_, _) {
          starts++;
          return Future.value(
            const AgentResult(status: 'completed', messages: []),
          );
        },
        onEvent: (_, _, _) async {},
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      final followup = _tool(tree, 'followup_task');
      final created = await spawn.call({
        'task_name': 'worker',
        'message': 'first turn',
      });
      final id = (created as Map<String, Object?>)['agent_id'] as String;
      await _tool(tree, 'wait_agent').call({'target': id});

      final followupFuture = followup.call({
        'target': id,
        'message': 'should remain queued',
      });
      await preparationStarted.future;
      final closing = tree.close();
      preparation.complete();

      final result = await followupFuture as Map<String, Object?>;
      await closing;
      expect(result['starts_turn'], isFalse);
      expect(result['interrupted'], isTrue);
      expect(starts, 1);
    },
  );

  test(
    'automatic follow-up waits for one shared slot, not all siblings',
    () async {
      final firstRun = Completer<AgentResult>();
      final secondRun = Completer<AgentResult>();
      final thirdRun = Completer<AgentResult>();
      final followupRun = Completer<AgentResult>();
      final thirdStarted = Completer<void>();
      final followupStarted = Completer<void>();
      var firstStarts = 0;
      var fillerSpawned = false;
      late AgentTool spawn;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(maxConcurrentThreads: 2),
        prepare: (_, {required followup}) async {},
        start: (node, _) {
          switch (node.taskName) {
            case 'first':
              firstStarts++;
              if (firstStarts == 1) return firstRun.future;
              followupStarted.complete();
              return followupRun.future;
            case 'second':
              return secondRun.future;
            case 'third':
              thirdStarted.complete();
              return thirdRun.future;
          }
          throw StateError('unexpected task');
        },
        onEvent: (node, type, _) async {
          if (node.taskName == 'first' &&
              type == 'subagent.completed' &&
              !fillerSpawned) {
            fillerSpawned = true;
            await spawn.call({
              'task_name': 'third',
              'message': 'fill the available slot',
            });
          }
        },
        interrupt: (node) async {
          final run = switch (node.taskName) {
            'first' => firstStarts == 1 ? firstRun : followupRun,
            'second' => secondRun,
            'third' => thirdRun,
            _ => null,
          };
          if (run != null && !run.isCompleted) {
            run.complete(const AgentResult(status: 'cancelled', messages: []));
          }
        },
      );
      spawn = _tool(tree, 'spawn_agent');
      final followup = _tool(tree, 'followup_task');
      final first = await spawn.call({
        'task_name': 'first',
        'message': 'first turn',
      });
      final firstId = (first as Map<String, Object?>)['agent_id'] as String;
      await spawn.call({'task_name': 'second', 'message': 'second turn'});
      await followup.call({'target': firstId, 'message': 'continue first'});

      firstRun.complete(
        const AgentResult(status: 'completed', messages: [], finalText: 'done'),
      );
      await thirdStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(firstStarts, 1);

      secondRun.complete(
        const AgentResult(status: 'completed', messages: [], finalText: 'free'),
      );
      await followupStarted.future;
      expect(firstStarts, 2);
      followupRun.complete(
        const AgentResult(
          status: 'completed',
          messages: [],
          finalText: 'continued',
        ),
      );
      await tree.close();
      expect(tree.hasActiveAgents, isFalse);
    },
  );

  test(
    'explicit follow-up during completion does not start a duplicate turn',
    () async {
      final firstRun = Completer<AgentResult>();
      final secondRun = Completer<AgentResult>();
      final secondStarted = Completer<void>();
      final prompts = <String>[];
      late AgentTool followup;
      var explicitFollowupSent = false;
      final tree = SubagentTree(
        rootTaskId: 'root',
        settings: const SubagentSettings(),
        prepare: (_, {required followup}) async {},
        start: (_, prompt) {
          prompts.add(prompt);
          if (prompts.length == 1) return firstRun.future;
          if (!secondStarted.isCompleted) secondStarted.complete();
          return secondRun.future;
        },
        onEvent: (node, type, _) async {
          if (type == 'subagent.completed' && !explicitFollowupSent) {
            explicitFollowupSent = true;
            await followup.call({
              'target': node.id,
              'message': 'explicit follow-up',
            });
          }
        },
        interrupt: (_) async {},
      );
      final spawn = _tool(tree, 'spawn_agent');
      followup = _tool(tree, 'followup_task');
      final created = await spawn.call({
        'task_name': 'worker',
        'message': 'first turn',
      });
      final id = (created as Map<String, Object?>)['agent_id'] as String;
      await followup.call({'target': id, 'message': 'queued follow-up'});

      firstRun.complete(
        const AgentResult(status: 'completed', messages: [], finalText: 'done'),
      );
      await secondStarted.future;
      secondRun.complete(
        const AgentResult(
          status: 'completed',
          messages: [],
          finalText: 'continued',
        ),
      );
      await tree.waitForChildren();

      expect(prompts, ['first turn', 'queued follow-up\n\nexplicit follow-up']);
    },
  );
}

AgentTool _tool(SubagentTree tree, String name, {String parentId = 'root'}) {
  return tree
      .toolsFor(parentId)
      .firstWhere((tool) => tool.definition.name == name);
}
