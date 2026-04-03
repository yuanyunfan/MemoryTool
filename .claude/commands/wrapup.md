Session 即将结束。请执行以下收尾操作：

1. **更新 claude-progress.txt**:
   - Current Status 改为当前实际状态
   - 将本次完成的内容移到 Completed 区
   - 更新 Not Started 列表
   - 在 Architecture Notes 补充本次的关键决策（如有）

2. **更新 feature_list.json**:
   - 将已完成的 feature 标记 passes: true
   - 更新 phase status（如该 phase 全部完成则改为 "done"）
   - 重算 summary（total/done/remaining/progress_pct）

3. **更新 CHANGELOG.md**（仅当有显著功能完成时）

4. 给我一个 3-5 行的 session 总结。
