"""带未知端点与精度的时间区间。

约定:
  区间为左闭右开 [start, end)。
  端点可为 None:
    start is None  -> 起点未知; end is None -> 终点未知(可能持续至今)。
  精度 precision:
    day/month/year 给出"确定的最早/最晚可解析边界";
    unknown 表示端点缺失。
  为避免把未知说成事实, 查询区分:
    definitely_contains : 确定覆盖
    possibly_contains   : 因端点未知/约略而仅可能覆盖
"""
from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime, date, time
from typing import Optional

PREC_OPEN = {"day": "00:00:00", "month": "-01T00:00:00", "year": "-01-01T00:00:00"}
# 某精度"格子"的上界(右端点), 右开
PREC_NEXT = {
    "day": (1, None),       # 占位, 实际用日期加一天
    "month": (None, 1),     # 加一月
    "year": (None, None, 1),
}


def parse_dt(value: Optional[str]) -> Optional[datetime]:
    if value is None:
        return None
    v = value.strip().replace(" ", "T")
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d", "%Y-%m", "%Y"):
        try:
            return datetime.strptime(v, fmt)
        except ValueError:
            continue
    raise ValueError(f"无法解析时间值: {value!r}")


def _add_months(y: int, m: int, d: int, months: int) -> datetime:
    total = (y * 12 + (m - 1)) + months
    return datetime(total // 12, total % 12 + 1, d)


@dataclass(frozen=True)
class Interval:
    start: Optional[datetime]
    end: Optional[datetime]
    start_prec: str = "unknown"
    end_prec: str = "unknown"

    @classmethod
    def of(cls, start_value, start_prec, end_value, end_prec) -> "Interval":
        return cls(parse_dt(start_value), parse_dt(end_value), start_prec, end_prec)

    def definite_start(self) -> Optional[datetime]:
        """已知起点: day 精度取当天 00:00; month 取 1 日; year 取 1 月 1 日。"""
        if self.start is None:
            return None
        if self.start_prec in ("instant", "day"):
            return datetime.combine(self.start.date(), time.min)
        if self.start_prec == "month":
            return datetime(self.start.year, self.start.month, 1)
        if self.start_prec == "year":
            return datetime(self.start.year, 1, 1)
        return None

    def definite_end(self) -> Optional[datetime]:
        """已知终点(右开): day 精度=次日00:00; month=次月1日; year=次年1月1日。"""
        if self.end is None:
            return None
        d = self.end
        if self.end_prec in ("instant", "day"):
            return datetime.combine(d.date(), time.min)
        if self.end_prec == "month":
            return _add_months(d.year, d.month, 1, 1)
        if self.end_prec == "year":
            return datetime(d.year + 1, 1, 1)
        return None

    def earliest_possible_start(self) -> Optional[datetime]:
        return self.definite_start()

    def latest_possible_end(self) -> Optional[datetime]:
        """终点未知 => 视为可能无限; month/year 精度取格子右界。"""
        return self.definite_end()

    def definitely_contains(self, t: datetime) -> bool:
        s = self.definite_start()
        e = self.definite_end()
        if s is not None and t < s:
            return False
        if e is not None and t >= e:
            return False
        # 端点缺失 => 无法确定
        if self.start is None or self.end is None:
            return False
        return True

    def possibly_contains(self, t: datetime) -> bool:
        # 起点未知: 可能早已开始; 终点未知: 可能仍在持续
        s = self.definite_start()
        e = self.latest_possible_end()
        if s is not None and t < s:
            return False          # 明确还没开始
        if e is not None and t >= e:
            return False          # 明确已结束(格子右界之外)
        return True


def interval_status(iv: Interval, t: datetime) -> str:
    """返回 definite / possible / none。"""
    if iv.definitely_contains(t):
        return "definite"
    if iv.possibly_contains(t):
        return "possible"
    return "none"


def overlapping_definite(a: Interval, b: Interval) -> bool:
    sa, ea = a.definite_start(), a.definite_end()
    sb, eb = b.definite_start(), b.definite_end()
    if None in (sa, ea, sb, eb):
        return False
    return sa < eb and sb < ea


def overlapping_possible(a: Interval, b: Interval) -> bool:
    sa = a.earliest_possible_start()
    eb = b.latest_possible_end()
    sb = b.earliest_possible_start()
    ea = a.latest_possible_end()
    if sa is not None and eb is not None and sa >= eb:
        return False
    if sb is not None and ea is not None and sb >= ea:
        return False
    return True


def semver_tuple(v: str):
    parts = v.strip().split(".")
    if len(parts) != 3:
        raise ValueError(f"版本号必须是 x.y.z: {v!r}")
    return tuple(int(p) for p in parts)
