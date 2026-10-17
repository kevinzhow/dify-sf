import sys, os
sys.path.insert(0, 'calib')
from summarize import summ
sets = [('s1n_lat0', 's1n', 'S1N 自然时序（Playwright gather，40 轮）'), ('s1n_fast', 's1n', 'S1N 同时提交（预置面板后同时 blur，30 轮）'),
        ('s2o_lat0', 's2o', 'S2O 自然时序（23 轮）'), ('s2o_fast', 's2o', 'S2O 快速同时（17 轮）'), ('s2_lat400', 's2', 'S2 同标题 + 400 ms（8 轮）')]
print('| 录制集 | 轮数 | 真实丢失 | 模拟(理想主线程)预测丢失 | 模拟(校准主线程)预测丢失 | 结果类别一致(众数) 理想 / 校准 | 归一化存档逐字节一致 理想 / 校准 |')
print('|---|---|---|---|---|---|---|')
for name, scen, label in sets:
    r0 = summ(f'out/calib-{name}-R0.txt', scen) if os.path.exists(f'out/calib-{name}-R0.txt') else None
    r2 = summ(f'out/calib-{name}-R2.txt', scen) if os.path.exists(f'out/calib-{name}-R2.txt') else None
    if not r0: continue
    r2 = r2 or r0
    print(f"| {label} | {r0['n']} | {r0['real_loss']} | {r0['pred_loss']} | {r2['pred_loss']} | {r0['modal_agree']} / {r2['modal_agree']} | {r0['byte_equal']} / {r2['byte_equal']} |")
