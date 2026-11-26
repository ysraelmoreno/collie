import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from planner import plan  # noqa: E402


def edge(frm, to, target, action="tap", obsolete=False, count=1, **extra):
    e = {"from": frm, "to": to, "action": action, "target": target, "app": "com.example.shop", "appVersion": "1.0",
         "count": count, "obsolete": obsolete}
    e.update(extra)
    return e


def graph(edges, goals=None):
    nodes = sorted({e["from"] for e in edges} | {e["to"] for e in edges})
    return {"nodes": nodes, "edges": edges, "goals": goals or {"checkout": "checkout"}, "skipped": 0}


class PlannerTests(unittest.TestCase):
    def test_shortest_of_two_paths(self):
        g = graph([edge("home", "list", "Produtos"), edge("list", "cart", "Carrinho"), edge("cart", "checkout", "Finalizar"),
                   edge("home", "cart", "Ícone carrinho"), edge("cart", "list", "Voltar")])
        p, why = plan(g, "home", "checkout")
        self.assertIsNone(why)
        self.assertEqual([s["target"] for s in p["steps"]], ["Ícone carrinho", "Finalizar"])

    def test_obsolete_edge_never_used(self):
        g = graph([edge("home", "checkout", "Atalho", obsolete=True),
                   edge("home", "cart", "Carrinho"), edge("cart", "checkout", "Finalizar")])
        p, _ = plan(g, "home", "checkout")
        self.assertEqual([s["target"] for s in p["steps"]], ["Carrinho", "Finalizar"])

    def test_only_obsolete_path_gives_reason(self):
        g = graph([edge("home", "checkout", "Atalho", obsolete=True), edge("home", "list", "Produtos")])
        p, why = plan(g, "home", "checkout")
        self.assertIsNone(p)
        self.assertIn("sem caminho", why)

    def test_unknown_goal_and_start(self):
        g = graph([edge("home", "checkout", "Ir")])
        self.assertIn("meta desconhecida", plan(g, "home", "login")[1])
        self.assertIn("fora do grafo", plan(g, "nowhere", "checkout")[1])
        self.assertIn("sem tela de partida", plan(g, "", "checkout")[1])
        self.assertIn("já está", plan(g, "checkout", "checkout")[1])

    def test_plan_has_d6_shape(self):
        g = graph([edge("home", "cart", "Carrinho"), edge("cart", "checkout", "Finalizar")])
        p, _ = plan(g, "home", "checkout")
        self.assertEqual(set(p), {"steps"})
        for s in p["steps"]:
            self.assertEqual(set(s), {"action", "target", "expectSig"})
            for k in ("action", "target", "expectSig"):
                self.assertIsInstance(s[k], str)
        self.assertEqual(p["steps"][-1]["expectSig"], "checkout")
        self.assertEqual(p["steps"][0], {"action": "tap", "target": "Carrinho", "expectSig": "cart"})

    def test_destructive_edge_is_marked(self):
        g = graph([edge("cart", "done", "Pagar", destructive=True)], goals={"paid": "done"})
        p, _ = plan(g, "cart", "paid")
        self.assertIs(p["steps"][0]["destructive"], True)

    def test_goal_by_signature_and_tie_prefers_most_seen(self):
        g = graph([edge("home", "checkout", "Raro", count=1), edge("home", "checkout", "Comum", count=5)])
        p, _ = plan(g, "home", "checkout")
        self.assertEqual(p["steps"][0]["target"], "Comum")
        g["goals"] = {}
        self.assertIsNotNone(plan(g, "home", "checkout")[0])


if __name__ == "__main__":
    unittest.main()
