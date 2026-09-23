"""Pydantic models mirroring docs/API_CONTRACT.md exactly.

Field names are snake_case in Python but every model carries an explicit
camelCase alias matching the JSON contract. Export with
``model.model_dump(mode="json", by_alias=True, exclude_none=False)``.
"""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

Franchise = Literal["bangdream", "lovelive"]
EventType = Literal["live", "fanMeeting", "screening", "other"]
EventStatus = Literal["scheduled", "postponed", "cancelled", "finished"]
PriceKind = Literal["full", "upgradeDifference", "streaming", "under20"]
TicketRoundKind = Literal["lottery", "firstComeFirstServed", "resale", "upgrade", "other"]
GoodsChannel = Literal["online", "venue"]
GoodsFulfillment = Literal["shipping", "venuePickup"]
GoodsPhase = Literal["pre", "during", "post"]
MediaKind = Literal[
    "keyVisual",
    "goodsList",
    "venueGoodsNotice",
    "goodsAreaMap",
    "eventSeatingMap",
    "venueGenericSeatingMap",
]
NoticeKind = Literal["change", "cancellation", "postponement", "refund", "other"]
Verification = Literal["confirmed", "needsReview", "conflict"]

DataStatus = Literal["confirmed", "officiallyTBA", "notFetched", "parseFailed", "notApplicable"]


class Scope(BaseModel):
    """适用范围 (see API_CONTRACT.md)."""

    model_config = ConfigDict(populate_by_name=True)

    kind: Literal["wholeEvent", "stop", "performances", "unconfirmed"]
    stop_id: str | None = Field(default=None, alias="stopID")
    performance_ids: list[str] | None = Field(default=None, alias="performanceIDs")

    @classmethod
    def whole_event(cls) -> "Scope":
        return cls(kind="wholeEvent")

    @classmethod
    def unconfirmed(cls) -> "Scope":
        return cls(kind="unconfirmed")

    @classmethod
    def for_performances(cls, performance_ids: list[str]) -> "Scope":
        return cls(kind="performances", performance_ids=performance_ids)

    @classmethod
    def for_stop(cls, stop_id: str) -> "Scope":
        return cls(kind="stop", stop_id=stop_id)


class LiveEvent(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    franchise: Franchise
    official_title: str = Field(alias="officialTitle")
    groups: list[str] = Field(default_factory=list)
    event_type: EventType = Field(alias="eventType")
    status: EventStatus
    primary_source_url: str = Field(alias="primarySourceURL")
    time_zone: str = Field(default="Asia/Tokyo", alias="timeZone")


class Stop(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    name: str
    order: int


class Performance(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    stop_id: str | None = Field(default=None, alias="stopID")
    day_label: str | None = Field(default=None, alias="dayLabel")
    subtitle: str | None = None
    local_date: str | None = Field(default=None, alias="localDate")
    doors_at: str | None = Field(default=None, alias="doorsAt")
    start_at: str | None = Field(default=None, alias="startAt")
    venue_name: str | None = Field(default=None, alias="venueName")
    venue_city: str | None = Field(default=None, alias="venueCity")
    performers: list[str] = Field(default_factory=list)
    order: int = 1


class TicketTier(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    name: str
    price_jpy: int | None = Field(default=None, alias="priceJPY")
    price_kind: PriceKind = Field(alias="priceKind")
    includes: str | None = None
    fee_note: str | None = Field(default=None, alias="feeNote")
    tax_note: str | None = Field(default=None, alias="taxNote")


class TicketRound(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    official_name: str = Field(alias="officialName")
    kind: TicketRoundKind
    scope: Scope
    apply_start_at: str | None = Field(default=None, alias="applyStartAt")
    apply_end_at: str | None = Field(default=None, alias="applyEndAt")
    result_at: str | None = Field(default=None, alias="resultAt")
    payment_deadline_at: str | None = Field(default=None, alias="paymentDeadlineAt")
    eligibility: str | None = None
    announcement_url: str | None = Field(default=None, alias="announcementURL")
    apply_url: str | None = Field(default=None, alias="applyURL")
    overseas_url: str | None = Field(default=None, alias="overseasURL")
    official_status: str | None = Field(default=None, alias="officialStatus")
    status: DataStatus = "confirmed"


class TicketOffer(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    round_id: str = Field(alias="roundID")
    tier_id: str = Field(alias="tierID")
    performance_ids: list[str] = Field(default_factory=list, alias="performanceIDs")
    price_jpy: int | None = Field(default=None, alias="priceJPY")


class GoodsCampaign(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    official_name: str = Field(alias="officialName")
    channel: GoodsChannel
    fulfillment: GoodsFulfillment
    phase: GoodsPhase
    scope: Scope
    sales_start_at: str | None = Field(default=None, alias="salesStartAt")
    sales_end_at: str | None = Field(default=None, alias="salesEndAt")
    pickup_window: str | None = Field(default=None, alias="pickupWindow")
    shipping_note: str | None = Field(default=None, alias="shippingNote")
    location: str | None = None
    requires_ticket: bool | None = Field(default=None, alias="requiresTicket")
    purchase_limit: str | None = Field(default=None, alias="purchaseLimit")
    payment_methods: str | None = Field(default=None, alias="paymentMethods")
    url: str | None = None
    media_asset_ids: list[str] = Field(default_factory=list, alias="mediaAssetIDs")
    status: DataStatus = "confirmed"


class MediaAsset(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    kind: MediaKind
    original_url: str = Field(alias="originalURL")
    thumbnail_url: str | None = Field(default=None, alias="thumbnailURL")
    scope: Scope
    source_url: str = Field(alias="sourceURL")
    version: int = 1
    caption: str | None = None


class Notice(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    event_id: str = Field(alias="eventID")
    kind: NoticeKind
    title: str
    body: str
    published_at: str | None = Field(default=None, alias="publishedAt")
    source_url: str = Field(alias="sourceURL")
    scope: Scope


class SourceEvidence(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    record_id: str = Field(alias="recordID")
    field: str
    source_url: str = Field(alias="sourceURL")
    quote: str
    source_published_at: str | None = Field(default=None, alias="sourcePublishedAt")
    verified_at: str = Field(alias="verifiedAt")
    verification: Verification = "needsReview"


class LiveEventBundle(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    schema_version: int = Field(default=1, alias="schemaVersion")
    published_at: str = Field(alias="publishedAt")
    event: LiveEvent
    stops: list[Stop] = Field(default_factory=list)
    performances: list[Performance] = Field(default_factory=list)
    ticket_tiers: list[TicketTier] = Field(default_factory=list, alias="ticketTiers")
    ticket_rounds: list[TicketRound] = Field(default_factory=list, alias="ticketRounds")
    ticket_offers: list[TicketOffer] = Field(default_factory=list, alias="ticketOffers")
    goods_campaigns: list[GoodsCampaign] = Field(default_factory=list, alias="goodsCampaigns")
    media_assets: list[MediaAsset] = Field(default_factory=list, alias="mediaAssets")
    notices: list[Notice] = Field(default_factory=list)
    evidence: list[SourceEvidence] = Field(default_factory=list)


# --- Internal (non-contract) models used by the pipeline before publish ---


class Issue(BaseModel):
    """A parsing problem recorded instead of guessing a value."""

    field: str
    message: str
    severity: Literal["info", "warning", "error"] = "warning"


class AliasRelation(BaseModel):
    """Old source URL -> new source URL migration (e.g. store portal moves)."""

    old_url: str
    new_url: str
    reason: str
