"""Registry of official sources (DESIGN.md 一) and their URL alias/migration table."""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel

FetchTier = Literal["low", "medium", "high"]


class SourceDef(BaseModel):
    id: str
    franchise: Literal["bangdream", "lovelive"]
    url: str
    template: str
    adapter: str
    fetch_tier: FetchTier
    note: str = ""


SOURCES: list[SourceDef] = [
    SourceDef(
        id="bangdream:events_index",
        franchise="bangdream",
        url="https://bang-dream.com/events/",
        template="bangdream_event_list",
        adapter="BangDreamEventIndexAdapter",
        fetch_tier="medium",
        note="官方演出与活动发现入口",
    ),
    SourceDef(
        id="bangdream:event_detail",
        franchise="bangdream",
        url="https://bang-dream.com/events/{slug}/",
        template="bangdream_event_detail",
        adapter="BangDreamEventDetailAdapter",
        fetch_tier="high",
        note="单场公演详情页，作为主来源；例 mygo-avemujica2026",
    ),
    SourceDef(
        id="bushiroad:live_goods_list",
        franchise="bangdream",
        url="https://bushiroad-store.com/blogs/live",
        template="bushiroad_live_goods_list",
        adapter="BushiroadLiveGoodsAdapter",
        fetch_tier="medium",
        note="按演出组织的通贩文章列表，含分页；需人工/关联链接筛选属于哪项公演",
    ),
    SourceDef(
        id="bushiroad:live_goods_article",
        franchise="bangdream",
        url="https://bushiroad-store.com/blogs/live/{slug}",
        template="bushiroad_live_goods_article",
        adapter="BushiroadLiveGoodsAdapter",
        fetch_tier="medium",
        note="通贩文章正文，可能按 DAY1/DAY2/DAY3 拆分",
    ),
    SourceDef(
        id="lovelive:news",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/news/",
        template="lovelive_news_list",
        adapter="LoveLiveNewsAdapter",
        fetch_tier="medium",
        note="新公演发布、追加信息、变更公告的总入口",
    ),
    SourceDef(
        id="lovelive:aqours_live",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/uranohoshi/live.php",
        template="lovelive_index_legacy_php",
        adapter="LoveLiveIndexAdapter",
        fetch_tier="medium",
        note="Aqours 分支演出入口（旧 .php 模板）",
    ),
    SourceDef(
        id="lovelive:nijigasaki_live",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/nijigasaki/live.php",
        template="lovelive_index_legacy_php",
        adapter="LoveLiveIndexAdapter",
        fetch_tier="medium",
        note="虹咲分支演出入口（旧 .php 模板）",
    ),
    SourceDef(
        id="lovelive:liella_live",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/yuigaoka/live/",
        template="lovelive_index_new",
        adapter="LoveLiveIndexAdapter",
        fetch_tier="medium",
        note="Liella! 分支演出入口（新 /live/ 模板）",
    ),
    SourceDef(
        id="lovelive:hasunosora_live_event",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/hasunosora/live-event/",
        template="lovelive_index_new_variant",
        adapter="LoveLiveIndexAdapter",
        fetch_tier="medium",
        note="莲之空分支公演及活动入口",
    ),
    SourceDef(
        id="lovelive:lovehigh_live",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/lovehigh/live/",
        template="lovelive_index_tailwind",
        adapter="LoveLiveIndexAdapter",
        fetch_tier="medium",
        note="イキヅライブ！ 分支入口；detail 链接使用 _id 而非 p",
    ),
    SourceDef(
        id="lovelive:special_detail",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/special/live/live_detail.php?p={id}",
        template="lovelive_detail",
        adapter="LoveLiveDetailAdapter",
        fetch_tier="high",
        note="跨系列/分支新式特设详情页",
    ),
    SourceDef(
        id="lovelive:legacy_merch_page",
        franchise="lovelive",
        url="https://www.lovelive-anime.jp/{branch}/sp_{slug}_merch.php",
        template="lovelive_legacy_merch",
        adapter="LoveLiveLegacyPageAdapter",
        fetch_tier="low",
        note="历史公演独立物贩/票务分页面",
    ),
    SourceDef(
        id="lovelive:store_portal",
        franchise="lovelive",
        url="https://lovelive-store.bnfw.jp/",
        template="lovelive_store_portal",
        adapter="LoveLiveGoodsStoreAdapter",
        fetch_tier="low",
        note="官方通贩发现门户",
    ),
    SourceDef(
        id="lovelive:goods_store_legacy",
        franchise="lovelive",
        url="https://official-goods-store.jp/lovelive/",
        template="lovelive_goods_store_migration",
        adapter="LoveLiveGoodsStoreAdapter",
        fetch_tier="low",
        note="旧 LIVE GOODS 商店，显示迁移公告 -> maintenance -> fannect",
    ),
    SourceDef(
        id="lovelive:fannect_store",
        franchise="lovelive",
        url="https://lovelive.fannect.jp/",
        template="lovelive_fannect_store",
        adapter="LoveLiveGoodsStoreAdapter",
        fetch_tier="low",
        note="School idol STORE，实际 Live Goods 店铺",
    ),
]

_BY_ID = {s.id: s for s in SOURCES}


def get_source(source_id: str) -> SourceDef | None:
    return _BY_ID.get(source_id)


def list_sources() -> list[SourceDef]:
    return list(SOURCES)


class AliasEntry(BaseModel):
    old_url: str
    new_url: str
    reason: str


# 已核实的来源迁移关系：官方通贩门户的 LIVE GOODS 链接经过旧站，
# 旧站显示维护/迁移公告，再指向 lovelive.fannect.jp。
ALIAS_TABLE: list[AliasEntry] = [
    AliasEntry(
        old_url="https://official-goods-store.jp/lovelive/",
        new_url="https://lovelive.fannect.jp/",
        reason="官方通贩门户 LIVE GOODS 链接迁移公告：旧站 -> fannect 新店铺",
    ),
]


def resolve_alias(url: str) -> str:
    for entry in ALIAS_TABLE:
        if url.rstrip("/") == entry.old_url.rstrip("/"):
            return entry.new_url
    return url
