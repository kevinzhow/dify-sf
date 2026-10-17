# A-tier catalog results (simulator, Dify 1.17.1 code path, CALIBRATED: link 36 ms +-20 per leg, measured main-thread latency)

Each cell = runs in which the metric occurred / K. M4 is reported as "collaboration-induced" (more dangling references than the serial single-user reference run of the same operations).

| case id | title | relation | timing | K | M1 | M2 | M3 | M4(collab) | M4(inherent in op) | M5 |
|---|---|---|---|---|---|---|---|---|---|---|
| A-setTitle-setTitle-R1-T1-F0-2p-01 | 两人同时改同一节点标题（并发） | R1 | T1 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setTitle-setTitle-R1-T2-F0-2p-01 | 两人同时改同一节点标题（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T1-F0-2p-02 | 两人同时改同一 LLM 温度（并发） | R1 | T1 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T2-F0-2p-02 | 两人同时改同一 LLM 温度（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T1-F0-2p-03 | 两人同时改同一代码块（并发） | R1 | T1 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T2-F0-2p-03 | 两人同时改同一代码块（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-moveNode-moveNode-R1-T1-F0-2p-04 | 两人同时拖动同一节点（并发） | R1 | T1 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-moveNode-moveNode-R1-T2-F0-2p-04 | 两人同时拖动同一节点（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setRef-setRef-R1-T1-F0-2p-05 | 两人同时改同一引用（并发） | R1 | T1 | 30 | 0 | 29 | 0 | 0 | - | 0 |
| A-setRef-setRef-R1-T2-F0-2p-05 | 两人同时改同一引用（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R1-T1-F0-2p-06 | 两人同时删同一输出变量（并发） | R1 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R1-T2-F0-2p-06 | 两人同时删同一输出变量（基于旧版本） | R1 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T1-F0-2p-07 | 两人同时改同一 if-else 条件值（并发） | R1 | T1 | 30 | 0 | 29 | 0 | 0 | - | 0 |
| A-setField-setField-R1-T2-F0-2p-07 | 两人同时改同一 if-else 条件值（基于旧版本） | R1 | T2 | 30 | 0 | 30 | 0 | 0 | - | 0 |
| A-setTitle-setField-R2-T1-F0-2p-08 | A 改标题，B 改代码（并发） | R2 | T1 | 30 | 9 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setField-R2-T2-F0-2p-08 | A 改标题，B 改代码（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setField-R2-T1-F0-2p-09 | A 改标题，B 改描述（并发） | R2 | T1 | 30 | 8 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setField-R2-T2-F0-2p-09 | A 改标题，B 改描述（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setTitle-moveNode-R2-T1-F0-2p-10 | A 改标题，B 拖动（并发） | R2 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-setTitle-moveNode-R2-T2-F0-2p-10 | A 改标题，B 拖动（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-moveNode-R2-T1-F0-2p-11 | A 改温度，B 拖动（并发） | R2 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-setField-moveNode-R2-T2-F0-2p-11 | A 改温度，B 拖动（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R2-T1-F0-2p-12 | A 改提示词，B 改温度（并发） | R2 | T1 | 30 | 11 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R2-T2-F0-2p-12 | A 改提示词，B 改温度（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setRef-R2-T1-F0-2p-13 | A 改标题，B 改引用（并发） | R2 | T1 | 30 | 9 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setRef-R2-T2-F0-2p-13 | A 改标题，B 改引用（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-moveNode-setField-R2-T1-F0-2p-14 | A 拖动，B 改描述（并发） | R2 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-moveNode-setField-R2-T2-F0-2p-14 | A 拖动，B 改描述（基于旧版本） | R2 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R3-T1-F0-2p-15 | A 换模型，B 改温度（路径重叠）（并发） | R3 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R3-T2-F0-2p-15 | A 换模型，B 改温度（路径重叠）（基于旧版本） | R3 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R3-T1-F0-2p-16 | A 改温度，B 换模型（路径重叠，顺序对调）（并发） | R3 | T1 | 30 | 29 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R3-T2-F0-2p-16 | A 改温度，B 换模型（路径重叠，顺序对调）（基于旧版本） | R3 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T1-F0-2p-17 | 两人各加一个输出变量（并发） | R4 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T2-F0-2p-17 | 两人各加一个输出变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T1-F0-2p-18 | 两人各加一个输入变量（并发） | R4 | T1 | 30 | 9 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T2-F0-2p-18 | 两人各加一个输入变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T1-F0-2p-19 | 两人各加一条提示词（并发） | R4 | T1 | 30 | 16 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listInsert-R4-T2-F0-2p-19 | 两人各加一条提示词（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listRemove-R4-T1-F0-2p-20 | A 加输出变量，B 删另一个输出变量（并发） | R4 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listRemove-R4-T2-F0-2p-20 | A 加输出变量，B 删另一个输出变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listRemove-R4-T1-F0-2p-21 | A 加输入变量，B 删另一个输入变量（并发） | R4 | T1 | 30 | 13 | 0 | 0 | 0 | - | 0 |
| A-listInsert-listRemove-R4-T2-F0-2p-21 | A 加输入变量，B 删另一个输入变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R4-T1-F0-2p-22 | 两人各删一个不同的输出变量（并发） | R4 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R4-T2-F0-2p-22 | 两人各删一个不同的输出变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R4-T1-F0-2p-23 | 两人各删一个不同的输入变量（并发） | R4 | T1 | 30 | 28 | 0 | 0 | 0 | - | 0 |
| A-listRemove-listRemove-R4-T2-F0-2p-23 | 两人各删一个不同的输入变量（基于旧版本） | R4 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setTitle-R5-T1-F0-2p-24 | 两人改不同节点的标题（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setTitle-setTitle-R5-T2-F0-2p-24 | 两人改不同节点的标题（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-moveNode-moveNode-R5-T1-F0-2p-25 | 两人拖动不同节点（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-moveNode-moveNode-R5-T2-F0-2p-25 | 两人拖动不同节点（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R5-T1-F0-2p-26 | 两人改不同节点的字段（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setField-setField-R5-T2-F0-2p-26 | 两人改不同节点的字段（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-addNode-R5-T1-F0-2p-27 | 两人各加一个节点（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-addNode-R5-T2-F0-2p-27 | 两人各加一个节点（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeNode-setTitle-R5-T1-F0-2p-28 | A 删节点，B 改另一个节点（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeNode-setTitle-R5-T2-F0-2p-28 | A 删节点，B 改另一个节点（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-moveNode-R5-T1-F0-2p-29 | A 加节点，B 拖动另一个节点（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-moveNode-R5-T2-F0-2p-29 | A 加节点，B 拖动另一个节点（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-setTitle-R5-T1-F0-2p-30 | A 连线，B 改另一个节点标题（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-setTitle-R5-T2-F0-2p-30 | A 连线，B 改另一个节点标题（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-moveNode-R5-T1-F0-2p-31 | A 断线，B 拖动无关节点（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-moveNode-R5-T2-F0-2p-31 | A 断线，B 拖动无关节点（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setRef-setRef-R5-T1-F0-2p-32 | 两人各改不同节点的引用（并发） | R5 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-setRef-setRef-R5-T2-F0-2p-32 | 两人各改不同节点的引用（基于旧版本） | R5 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeNode-setRef-R6-T1-F0-2p-33 | A 删节点 code1，B 让 code2 引用 code1 的输出（并发） | R6 | T1 | 30 | 0 | 0 | 0 | 0 | yes | 0 |
| A-removeNode-setRef-R6-T2-F0-2p-33 | A 删节点 code1，B 让 code2 引用 code1 的输出（基于旧版本） | R6 | T2 | 30 | 0 | 0 | 0 | 0 | yes | 0 |
| A-removeNode-listInsert-R6-T1-F0-2p-34 | A 删节点 code1，B 给 code1 加输出变量（并发） | R6 | T1 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-removeNode-listInsert-R6-T2-F0-2p-34 | A 删节点 code1，B 给 code1 加输出变量（基于旧版本） | R6 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeNode-setTitle-R6-T1-F0-2p-35 | A 删节点 code2，B 改 code2 标题（并发） | R6 | T1 | 30 | 29 | 0 | 0 | 0 | yes | 0 |
| A-removeNode-setTitle-R6-T2-F0-2p-35 | A 删节点 code2，B 改 code2 标题（基于旧版本） | R6 | T2 | 30 | 0 | 0 | 0 | 0 | yes | 0 |
| A-listRemove-setRef-R6-T1-F0-2p-36 | A 删 code1 的输出变量 result，B 让 llm1 提示词引用（并发） | R6 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-listRemove-setRef-R6-T2-F0-2p-36 | A 删 code1 的输出变量 result，B 让 llm1 提示词引用（基于旧版本） | R6 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-addEdge-R7-T1-F0-2p-37 | 两人连同一条线（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-addEdge-R7-T2-F0-2p-37 | 两人连同一条线（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-removeNode-R7-T1-F0-2p-38 | A 连线到 code3，B 删 code3（并发） | R7 | T1 | 30 | 2 | 0 | 0 | 28 | - | 0 |
| A-addEdge-removeNode-R7-T2-F0-2p-38 | A 连线到 code3，B 删 code3（基于旧版本） | R7 | T2 | 30 | 30 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-setTitle-R7-T1-F0-2p-39 | A 断线，B 在同一条线两端的节点上改标题（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-setTitle-R7-T2-F0-2p-39 | A 断线，B 在同一条线两端的节点上改标题（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-removeEdge-R7-T1-F0-2p-40 | 两人断开不同的线（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-removeEdge-R7-T2-F0-2p-40 | 两人断开不同的线（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-addEdge-R7-T1-F0-2p-41 | A 断线，B 连另一条线到同一节点（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeEdge-addEdge-R7-T2-F0-2p-41 | A 断线，B 连另一条线到同一节点（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-addEdge-R7-T1-F0-2p-42 | A 连线 start→code3，B 连线 code1→code3（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addEdge-addEdge-R7-T2-F0-2p-42 | A 连线 start→code3，B 连线 code1→code3（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-removeNode-addEdge-R7-T1-F0-2p-43 | A 删节点，B 连线到该节点（并发） | R7 | T1 | 30 | 11 | 0 | 0 | 19 | - | 0 |
| A-removeNode-addEdge-R7-T2-F0-2p-43 | A 删节点，B 连线到该节点（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-addNode-R7-T1-F0-2p-44 | A 加节点并连线，B 加另一节点并连到同一上游（并发） | R7 | T1 | 30 | 0 | 0 | 0 | 0 | - | 0 |
| A-addNode-addNode-R7-T2-F0-2p-44 | A 加节点并连线，B 加另一节点并连到同一上游（基于旧版本） | R7 | T2 | 30 | 0 | 0 | 0 | 0 | - | 0 |
