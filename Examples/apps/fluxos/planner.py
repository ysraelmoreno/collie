"""Fluxos planner (d9, spec docs/superpowers/specs/2026-11-26-device-flows-design.md, onda 3).

`plan(graph, from_sig, goal)` is the shortest path (BFS, live edges only) from a screen signature to a goal, as a
FlowPlan in the shape `collie device run --plan` reads (d6): {"steps": [{"action", "target", "expectSig"[, "destructive"]}]}.
It only builds the plan; running it is the agent's job with `device run`. Python 3.9 stdlib only.
"""

from collections import deque

MAX_STEPS = 200   # FlowPlan.maxSteps (d6)


def resolve(graph, goal):
    """The node a goal name points at; a goal that is already a node signature is itself."""
    goals = graph.get("goals") if isinstance(graph.get("goals"), dict) else {}
    return goals.get(goal) or goal


def plan(graph, from_sig, goal):
    """(FlowPlan, None) on success, (None, reason) when there is no plan."""
    if not from_sig:
        return None, "sem tela de partida: passe --from <sig> ou grave ações antes (actions.jsonl)"
    target = resolve(graph, goal)
    nodes = set(graph.get("nodes") or [])
    if target not in nodes:
        return None, "meta desconhecida: %s" % goal
    if from_sig not in nodes:
        return None, "tela de partida fora do grafo: %s" % from_sig
    if from_sig == target:
        return None, "já está na meta %s" % goal
    out = {}
    for e in graph.get("edges") or []:
        if not e.get("obsolete"):
            out.setdefault(e["from"], []).append(e)
    for edges in out.values():
        # ponytail: ties go to the most-seen edge, then name order; weighted (Dijkstra) when edges get costs
        edges.sort(key=lambda e: (-e.get("count", 0), e["action"], e.get("target", ""), e["to"]))
    came = {from_sig: None}
    queue = deque([from_sig])
    while queue:
        sig = queue.popleft()
        if sig == target:
            break
        for e in out.get(sig, []):
            if e["to"] not in came:
                came[e["to"]] = e
                queue.append(e["to"])
    if target not in came:
        return None, "sem caminho de %s até %s com arestas atuais (rode o fluxo uma vez para o Fluxos aprender)" % (from_sig, goal)
    path = []
    sig = target
    while came[sig] is not None:
        path.append(came[sig])
        sig = came[sig]["from"]
    path.reverse()
    if len(path) > MAX_STEPS:
        return None, "caminho com %d passos, o device run aceita até %d" % (len(path), MAX_STEPS)
    steps = []
    for e in path:
        step = {"action": e["action"], "target": e.get("target", ""), "expectSig": e["to"]}
        if e.get("destructive"):
            step["destructive"] = True
        steps.append(step)
    return {"steps": steps}, None
