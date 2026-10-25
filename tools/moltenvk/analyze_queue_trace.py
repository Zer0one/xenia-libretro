#!/usr/bin/env python3
"""Analyze the bounded local queue-trace format, not arbitrary application logs.

Signal/wait ordinal pairing assumes these harnesses' legal binary-semaphore
reuse. GPU completion means the recorded Metal command buffer completed; this
does not attempt to decode Metal's internal state or a display's scanout.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path


def analyze(events):
    scopes = {}
    active_submissions = {}
    gpu_done = {}
    textures = defaultdict(list)
    semaphores = {}
    lifetimes = {}
    missing_lifetimes = False
    for event in events:
        kind = event['event']
        if kind == 'CPU_BEGIN':
            scopes[event['scope']] = event
            active_submissions[event['object']] = event['scope']
        elif kind in ('RENDER_GPU_DONE', 'PRESENT_GPU_DONE'):
            scope = active_submissions.get(event['object'])
            if scope is not None:
                gpu_done[scope] = event
        elif kind == 'TEXTURE' and event['kind'] == 'render':
            textures[(event['scope'], event['object'])].append(event)
        elif kind == 'SEM_CREATE':
            identifier = len(lifetimes) + 1
            semaphores[event['object']] = identifier
            lifetimes[identifier] = {'created': event, 'signals': [], 'waits': []}
        elif kind in ('EVENT_SIGNAL', 'EVENT_WAIT'):
            identifier = semaphores.get(event['object'])
            if identifier is None:
                missing_lifetimes = True
                continue
            lifetimes[identifier]['signals' if kind == 'EVENT_SIGNAL' else 'waits'].append(event)
        elif kind == 'SEM_DESTROY':
            semaphores.pop(event['object'], None)

    identity_changes = []
    for (scope, image), records in textures.items():
        values = {record['texture'] for record in records}
        if len(values) > 1:
            identity_changes.append({'scope': scope, 'image': image,
                                     'textures': sorted(values), 'accesses': records})
    token_mismatches = []
    stale_targets = []
    for identifier, lifetime in lifetimes.items():
        signals, waits = lifetime['signals'], lifetime['waits']
        for number, (signal, wait) in enumerate(zip(signals, waits)):
            pair = {'lifetime': identifier, 'round': number + 1,
                    'signal': signal, 'wait': wait}
            if signal['value'] != wait['value']:
                token_mismatches.append(pair)
            if number:
                previous = signals[number - 1]
                completed = gpu_done.get(previous['scope'])
                if previous['value'] >= wait['value'] and completed and completed['seq'] < wait['seq']:
                    producer_done = gpu_done.get(signal['scope'])
                    consumer_done = gpu_done.get(wait['scope'])
                    pair.update(previous_signal=previous, previous_gpu_done=completed,
                                producer_gpu_done=producer_done, consumer_gpu_done=consumer_done,
                                consumer_completed_first=bool(producer_done and consumer_done and
                                    consumer_done['seq'] < producer_done['seq']))
                    stale_targets.append(pair)
    return {'events': len(events), 'cpu_scopes': len(scopes),
            'texture_identity_change_count': len(identity_changes),
            'texture_identity_changes': identity_changes,
            'semaphore_lifetimes': len(lifetimes),
            'missing_semaphore_lifetime_markers': missing_lifetimes,
            'token_mismatch_count': len(token_mismatches),
            'token_mismatches': token_mismatches[:32],
            'completed_signal_reused_as_later_wait_count': len(stale_targets),
            'consumer_completed_before_current_producer_count': sum(
                pair['consumer_completed_first'] for pair in stale_targets),
            'completed_signal_reused_as_later_wait': stale_targets[:32]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    result = analyze([json.loads(line) for line in arguments.trace.read_text().splitlines()])
    text = json.dumps(result, indent=2) + '\n'
    if arguments.output:
        arguments.output.write_text(text)
    else:
        print(text, end='')
