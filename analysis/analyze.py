"""Проверка гипотез и графики по витринам mart.* (база olist в локальном PostgreSQL).

Запуск из корня проекта: .venv/bin/python analysis/analyze.py
Результат: reports/results.json и reports/figures/*.png
"""
import json
import os
import warnings
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import psycopg
import statsmodels.formula.api as smf
from scipy import stats
from statsmodels.stats.proportion import confint_proportions_2indep, proportion_confint, proportions_ztest

ROOT = Path(__file__).resolve().parent.parent
FIG = ROOT / "reports" / "figures"
FIG.mkdir(parents=True, exist_ok=True)
# pandas предупреждает о соединениях не через SQLAlchemy; psycopg 3 с read_sql работает корректно
warnings.filterwarnings("ignore", message="pandas only supports SQLAlchemy")
DSN = os.environ.get("OLIST_DSN", "host=localhost dbname=olist")
FOLLOW_UP_DAYS = 180

# палитра: слоты 1 и 8 категориальной темы, последовательный синий, нейтральные чернила
BLUE, RED = "#2a78d6", "#e34948"
INK, INK_2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e6e5e0", "#fcfcfb"
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.8, "axes.axisbelow": True, "font.size": 10, "axes.titlesize": 12,
    "axes.titleweight": "bold", "axes.titlelocation": "left", "text.color": INK,
})


def q(sql):
    with psycopg.connect(DSN) as conn:
        return pd.read_sql(sql, conn)


def save(fig, name):
    fig.tight_layout()
    fig.savefig(FIG / name, dpi=160)
    plt.close(fig)


results = {}

# ---------- 1. Опоздание доставки и негативный отзыв ----------
rev = q("""SELECT is_late, review_score FROM mart.valid_orders
           WHERE delivered_ts IS NOT NULL AND review_score IS NOT NULL""")
rev["negative"] = rev.review_score <= 2
g = rev.groupby("is_late").negative.agg(["sum", "count"])
late, ontime = g.loc[True], g.loc[False]
z, p = proportions_ztest([late["sum"], ontime["sum"]], [late["count"], ontime["count"]])
lo, hi = confint_proportions_2indep(late["sum"], late["count"], ontime["sum"], ontime["count"], method="newcomb")
u = stats.mannwhitneyu(rev.review_score[rev.is_late], rev.review_score[~rev.is_late], alternative="less")
results["late_vs_negative_review"] = {
    "late_orders": int(late["count"]), "ontime_orders": int(ontime["count"]),
    "negative_pct_late": round(100 * late["sum"] / late["count"], 2),
    "negative_pct_ontime": round(100 * ontime["sum"] / ontime["count"], 2),
    "diff_pp_ci95": [round(100 * lo, 2), round(100 * hi, 2)],
    "z": round(float(z), 1), "p_value": float(p),
    "avg_score_late": round(rev.review_score[rev.is_late].mean(), 2),
    "avg_score_ontime": round(rev.review_score[~rev.is_late].mean(), 2),
    "mannwhitney_p": float(u.pvalue),
}

buckets = q("SELECT * FROM mart.delay_vs_review ORDER BY delay_bucket")
labels = [b.split(": ")[1] for b in buckets.delay_bucket]
colors = [RED if "опоздание" in b else BLUE for b in buckets.delay_bucket]
fig, ax = plt.subplots(figsize=(9, 4.2))
bars = ax.bar(labels, buckets.negative_review_pct, color=colors, width=0.7, edgecolor=SURFACE, linewidth=2)
for b, v in zip(bars, buckets.negative_review_pct):
    ax.text(b.get_x() + b.get_width() / 2, v + 1.2, f"{v:.0f}%", ha="center", color=INK, fontsize=9)
ax.set_title("Опоздание доставки — главный источник плохих отзывов")
ax.set_ylabel("Доля отзывов 1–2 звезды, %")
ax.set_ylim(0, 92)
ax.tick_params(axis="x", labelrotation=20)
ax.legend(handles=[plt.Rectangle((0, 0), 1, 1, color=BLUE), plt.Rectangle((0, 0), 1, 1, color=RED)],
          labels=["Доставлено к обещанной дате", "Опоздание"], frameon=False, loc="upper left")
save(fig, "01_delay_vs_negative_review.png")

# ---------- 2. Первый опыт и повторная покупка ----------
first = q(f"""
WITH v AS (
  SELECT *, row_number() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts, order_id) AS seq
    FROM mart.valid_orders
), f AS (
  -- повторная покупка — заказ в более поздний день; заказы того же дня считаются частью первой покупки
  SELECT v.*, (SELECT min(w.purchase_ts) FROM mart.valid_orders w
                WHERE w.customer_unique_id = v.customer_unique_id
                  AND w.purchase_ts::date > v.purchase_ts::date) AS next_ts
    FROM v WHERE seq = 1
)
SELECT customer_unique_id, customer_state, main_category, gmv, freight, is_late, review_score,
       date_trunc('quarter', purchase_ts)::date AS purchase_quarter,
       (next_ts IS NOT NULL AND next_ts <= purchase_ts + interval '{FOLLOW_UP_DAYS} days') AS repeat
  FROM f
 WHERE delivered_ts IS NOT NULL AND review_score IS NOT NULL
   AND purchase_ts >= '2017-01-01'  -- в 2016 году единицы заказов
   AND purchase_ts <= (SELECT max(purchase_ts) FROM mart.valid_orders) - interval '{FOLLOW_UP_DAYS} days'
""")
first["repeat"] = first["repeat"].astype(int)
first["is_late"] = first["is_late"].astype(int)
first["negative"] = (first.review_score <= 2).astype(int)
top_states = first.customer_state.value_counts().index[:8]
top_cats = first.main_category.value_counts().index[:15]
first["state"] = np.where(first.customer_state.isin(top_states), first.customer_state, "other")
first["category"] = np.where(first.main_category.isin(top_cats), first.main_category, "other")
first["log_gmv"] = np.log1p(first.gmv.astype(float))
first["freight_share"] = first.freight.astype(float) / (first.gmv.astype(float) + first.freight.astype(float))
first["quarter"] = first.purchase_quarter.astype(str)


def rate(mask):
    k, n = int(first.loc[mask, "repeat"].sum()), int(mask.sum())
    lo, hi = proportion_confint(k, n, method="wilson")
    return {"customers": n, "repeat": k, "repeat_pct": round(100 * k / n, 2),
            "ci95": [round(100 * lo, 2), round(100 * hi, 2)]}


groups = {
    "Первый заказ\nвовремя": first.is_late == 0,
    "Первый заказ\nс опозданием": first.is_late == 1,
    "Отзыв 4–5": first.review_score >= 4,
    "Отзыв 1–2": first.review_score <= 2,
}
rep = {k: rate(m) for k, m in groups.items()}
k1, n1 = first.repeat[first.is_late == 1].sum(), (first.is_late == 1).sum()
k0, n0 = first.repeat[first.is_late == 0].sum(), (first.is_late == 0).sum()
z2, p2 = proportions_ztest([k1, k0], [n1, n0])


# минимальный эффект, который тест различил бы с мощностью 80% при alpha = 0.05
def mde_pp(p0, n_a, n_b, alpha=0.05, power=0.8):
    from statsmodels.stats.power import NormalIndPower
    h = NormalIndPower().solve_power(nobs1=n_a, ratio=n_b / n_a, alpha=alpha, power=power)
    # обратное преобразование Коэна h для снижения доли от p0
    p1 = np.sin(np.arcsin(np.sqrt(p0)) - h / 2) ** 2
    return round(100 * (p0 - p1), 2)


mde = mde_pp(k0 / n0, n1, n0)

model = smf.logit("repeat ~ is_late + negative + log_gmv + freight_share + C(state) + C(category) + C(quarter)",
                  data=first).fit(disp=False, maxiter=200)
ci = model.conf_int()


def odds(term):
    return {"odds_ratio": round(float(np.exp(model.params[term])), 3),
            "ci95": [round(float(np.exp(ci.loc[term, 0])), 3), round(float(np.exp(ci.loc[term, 1])), 3)],
            "p_value": float(model.pvalues[term])}


results["first_order_and_repeat"] = {
    "follow_up_days": FOLLOW_UP_DAYS, "customers": int(len(first)),
    "overall_repeat_pct": round(100 * first.repeat.mean(), 2),
    "groups": {k.replace("\n", " "): v for k, v in rep.items()},
    "late_vs_ontime_z": round(float(z2), 2), "late_vs_ontime_p": float(p2),
    "late_vs_ontime_mde_pp": mde,
    "logit_controls": "штат (8 крупнейших + прочие), категория (15 + прочие), log(чек), доля доставки в чеке, квартал покупки",
    "logit_is_late": odds("is_late"), "logit_negative_review": odds("negative"),
    "logit_n": int(model.nobs), "logit_converged": bool(model.mle_retvals["converged"]), "logit_pseudo_r2": round(float(model.prsquared), 4),
}

fig, ax = plt.subplots(figsize=(8, 4.2))
names = list(rep)
vals = [rep[n]["repeat_pct"] for n in names]
err = [[v - rep[n]["ci95"][0] for n, v in zip(names, vals)], [rep[n]["ci95"][1] - v for n, v in zip(names, vals)]]
bars = ax.bar(names, vals, color=[BLUE, RED, BLUE, RED], width=0.6, edgecolor=SURFACE, linewidth=2,
              yerr=err, error_kw={"ecolor": INK_2, "elinewidth": 1.2, "capsize": 4})
for b, v, n in zip(bars, vals, names):
    ax.text(b.get_x() + b.get_width() / 2, rep[n]["ci95"][1] + 0.08, f"{v:.2f}%", ha="center", fontsize=9)
ax.set_title(f"Повторная покупка в течение {FOLLOW_UP_DAYS} дней после первого заказа")
ax.set_ylabel("Доля вернувшихся, % (95% ДИ)")
ax.set_ylim(0, max(r["ci95"][1] for r in rep.values()) * 1.25)
save(fig, "02_first_order_vs_repeat.png")

# ---------- 3. Удержание по когортам ----------
coh = q("""SELECT cohort_month, month_offset, customers, cohort_size FROM mart.cohort_retention
           WHERE cohort_month BETWEEN '2017-01-01' AND '2018-03-01' AND month_offset BETWEEN 1 AND 12""")
size = q("""SELECT cohort_month, cohort_size FROM mart.cohort_retention
            WHERE month_offset = 0 AND cohort_month BETWEEN '2017-01-01' AND '2018-03-01'""")
weighted = coh.groupby("month_offset").customers.sum() / size.cohort_size.sum() * 100
results["retention"] = {
    "cohorts": "2017-01 … 2018-03", "customers_in_cohorts": int(size.cohort_size.sum()),
    "weighted_retention_pct_by_month": {int(k): round(v, 3) for k, v in weighted.items()},
    "one_time_buyers_pct": float(q("""SELECT round(100.0 * avg((n = 1)::int), 2) AS v FROM
        (SELECT customer_unique_id, count(*) n FROM mart.valid_orders GROUP BY 1) s""").v[0]),
}
piv = coh.pivot(index="cohort_month", columns="month_offset", values="customers")
pct = piv.div(size.set_index("cohort_month").cohort_size, axis=0) * 100
# пустая клетка внутри наблюдаемого периода — ноль вернувшихся, а не пропуск
last = pd.Timestamp("2018-08-01")
for c in pct.index:
    for m in pct.columns:
        if np.isnan(pct.loc[c, m]) and pd.Timestamp(c) + pd.DateOffset(months=int(m)) <= last:
            pct.loc[c, m] = 0.0
from matplotlib.colors import LinearSegmentedColormap
cmap = LinearSegmentedColormap.from_list("blue", ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
fig, ax = plt.subplots(figsize=(9, 5.2))
im = ax.imshow(pct.values, cmap=cmap, aspect="auto", vmin=0, vmax=0.8)
ax.set_xticks(range(len(pct.columns)), [f"M{c}" for c in pct.columns])
ax.set_yticks(range(len(pct.index)), [pd.Timestamp(d).strftime("%Y-%m") for d in pct.index])
for i in range(pct.shape[0]):
    for j in range(pct.shape[1]):
        v = pct.values[i, j]
        if not np.isnan(v):
            ax.text(j, i, f"{v:.2f}", ha="center", va="center", fontsize=7,
                    color="white" if v > 0.45 else INK)
ax.grid(False)
ax.set_title("Удержание по когортам: доля покупателей, вернувшихся через N месяцев, %")
ax.set_ylabel("Месяц первой покупки")
fig.colorbar(im, ax=ax, fraction=0.03, pad=0.02).outline.set_visible(False)
save(fig, "03_cohort_retention.png")

# ---------- 4. Воронка продавцов по каналам ----------
fun = q("SELECT * FROM mart.seller_funnel ORDER BY mql DESC")
fun["channel"] = np.where(fun.mql >= 250, fun.origin, "other (мелкие каналы)")
agg = fun.groupby("channel")[["mql", "closed_active"]].sum()
chi2, p_chi, dof, _ = stats.chi2_contingency(np.c_[agg.closed_active, agg.mql - agg.closed_active])
agg["pct"] = 100 * agg.closed_active / agg.mql
agg[["lo", "hi"]] = [[100 * x for x in proportion_confint(k, n, method="wilson")] for k, n in zip(agg.closed_active, agg.mql)]
agg = agg.sort_values("pct")
results["seller_funnel"] = {
    "mql": int(fun.mql.sum()), "closed_active": int(fun.closed_active.sum()),
    "conversion_pct": round(100 * fun.closed_active.sum() / fun.mql.sum(), 2),
    "by_channel": {k: {"mql": int(r.mql), "closed_active": int(r.closed_active), "pct": round(r.pct, 2),
                       "ci95": [round(r.lo, 2), round(r.hi, 2)]} for k, r in agg.iterrows()},
    "chi2": round(float(chi2), 1), "dof": int(dof), "p_value": float(p_chi),
}
fig, ax = plt.subplots(figsize=(8, 4.2))
ax.barh(agg.index, agg.pct, color=BLUE, height=0.6, edgecolor=SURFACE, linewidth=2,
        xerr=[agg.pct - agg.lo, agg.hi - agg.pct], error_kw={"ecolor": INK_2, "elinewidth": 1.2, "capsize": 3})
for i, (v, n) in enumerate(zip(agg.pct, agg.mql)):
    ax.text(agg.hi.iloc[i] + 0.2, i, f"{v:.1f}%  (из {n})", va="center", fontsize=9, color=INK_2)
ax.set_title("Конверсия лида в активного продавца по каналу")
ax.set_xlabel("Конверсия, % (95% ДИ)")
ax.set_xlim(0, agg.hi.max() * 1.45)
ax.grid(axis="y", visible=False)
save(fig, "04_seller_funnel.png")

# ---------- 5. Динамика заказов и опозданий ----------
mk = q("SELECT * FROM mart.monthly_kpi WHERE purchase_month BETWEEN '2017-01-01' AND '2018-08-01' ORDER BY 1")
peak = mk.loc[mk.late_pct.idxmax()]
results["monthly"] = {
    "orders_2017": int(mk[mk.purchase_month.astype(str) < "2018-01-01"].orders.sum()),
    "late_pct_peak_month": str(peak.purchase_month)[:7], "late_pct_peak": float(peak.late_pct),
    "late_pct_median_month": float(mk.late_pct.median()),
}
fig, axes = plt.subplots(2, 1, figsize=(9, 5.6), sharex=True)
axes[0].plot(mk.purchase_month, mk.orders, color=BLUE, linewidth=2)
axes[0].set_title("Заказы в месяц")
axes[1].plot(mk.purchase_month, mk.late_pct, color=RED, linewidth=2)
axes[1].set_title("Доля заказов с опозданием, %")
axes[1].annotate(f"{peak.late_pct:.0f}%", (peak.purchase_month, peak.late_pct), textcoords="offset points",
                 xytext=(6, -4), fontsize=9, color=INK)
save(fig, "05_monthly_orders_and_late.png")

dl = q("SELECT count(*) n, avg(-delay_days) early, avg(delivery_days) days FROM mart.valid_orders WHERE delivered_ts IS NOT NULL")
results["delivery"] = {"delivered_orders": int(dl.n[0]), "avg_days_before_estimate": round(float(dl.early[0]), 1),
                       "avg_delivery_days": round(float(dl.days[0]), 1),
                       "late_pct": round(100 * float(rev.is_late.mean()), 2)}

(ROOT / "reports" / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2, default=str))
print(json.dumps(results, ensure_ascii=False, indent=2, default=str))
