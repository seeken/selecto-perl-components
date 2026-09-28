import {expect, test} from "@playwright/test";
import path from "node:path";

test("Explorer sends revisioned changes, restores full state, and invalidates after writes", async ({page}) => {
  await page.setContent(`<section id="selecto-channel-products" hx-ws:connect="/products/ws">
    <form data-sc-builder="products"></form></section>`);
  await page.addScriptTag({path: path.resolve("public/selecto-components/selecto-components.js")});
  const result = await page.evaluate(async () => {
    const channel = document.querySelector("section");
    const sent = [];
    const connection = {socket: {readyState: WebSocket.OPEN, send: data => sent.push(JSON.parse(data))}};
    function send(values) {
      const detail = {connection, message: {values, headers: {test: "header"}}};
      channel.dispatchEvent(new CustomEvent("htmx:ws:before:message:outgoing", {bubbles: true, detail}));
      return JSON.parse(detail.message.data);
    }
    async function receive(request_id, session) {
      const waiting = [];
      const detail = {connection, message: {json: async () => ({selecto: {request_id, session}})},
        waitUntil: work => waiting.push(work)};
      channel.dispatchEvent(new CustomEvent("htmx:ws:before:message:incoming", {bubbles: true, detail}));
      await Promise.all(waiting);
    }
    const initial = send({selecto_request_id: "one", field: ["id", "name"], page: "1", filter_value: "open"});
    await receive("one", {revision: 1, accepted: 1});
    const delta = send({selecto_request_id: "two", field: ["id", "name"], page: "2"});
    await receive("two", {resync: 1});
    await receive("two", {revision: 2, accepted: 1});
    document.dispatchEvent(new CustomEvent("selecto:records-changed"));
    const afterWrite = send({selecto_request_id: "three", field: ["id", "name"], page: "3"});
    await receive("three", {revision: 3, accepted: 1});
    channel.dispatchEvent(new CustomEvent("htmx:ws:after:connection", {bubbles: true, detail: {connection}}));
    const reconnect = send({selecto_request_id: "four", field: ["id", "name"], page: "4"});
    const concurrent = send({selecto_request_id: "five", field: ["id"], page: "1"});
    return {initial, delta, sent, afterWrite, reconnect, concurrent};
  });
  expect(result.initial.field).toEqual(["id", "name"]);
  expect(result.delta.selecto_session).toEqual({revision: 1, set: {page: "2"}, remove: ["filter_value"]});
  expect(result.sent).toHaveLength(1);
  expect(result.sent[0].field).toEqual(["id", "name"]);
  expect(result.sent[0].headers).toEqual({test: "header"});
  expect(result.afterWrite.selecto_refresh).toBe(1);
  expect(result.reconnect.selecto_session).toBeUndefined();
  expect(result.concurrent.selecto_session).toBeUndefined();
});
