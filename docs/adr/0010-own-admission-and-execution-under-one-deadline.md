# Own admission and execution under one request deadline

<a id="adr-0010"></a>

- Accepted by the repository owner on 8 October 2026: Relay owns the admitted request lifetime, with one deadline covering admission and execution. This supersedes the unresolved ownership ruling in [ADR 0008](0008-admission-budget-remains-unresolved.md); the earlier observed behavior remains historical evidence.
- Retaining synchronous callbacks in the serving process would preserve process affinity but require every application to enforce admission deadlines. A temporary admission-only worker would bound waiting but invalidate callback-created process resources as soon as admission returned. A managed worker retained through the exchange provides a coherent callback lifetime while a responsive coordinator enforces deadline and cancellation authority.
- Buffered callback process affinity deliberately changes. Borrowed application resources keep their application owner; arbitrary child processes and remote effects are not implicitly adopted. Retiring request work remains counted against capacity until termination, accepting a short period of continued overload refusal to prevent cleanup accumulation.
- The separate [Oversight admission consumer](../../../oversight/playground/relay_admission/README.md) records the failing deadline behavior and the Subject/child ownership counterexamples against Relay `754137581c0461189579676cb2089ad9f04eefa7`. Its red assertions are the implementation starting point; acceptance of this design does not establish passing runtime evidence.
