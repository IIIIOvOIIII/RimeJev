#import <Foundation/Foundation.h>
#include <algorithm>
#include <dlfcn.h>
#include <iostream>
#include <string>
#include <unistd.h>
#include <limits.h>
#include "rime_api.h"

static std::string hex(const std::string& value) {
  static const char* digits = "0123456789abcdef";
  std::string out;
  for (unsigned char c : value) { out += digits[c >> 4]; out += digits[c & 15]; }
  return out;
}

static NSDictionary *snapshot(RimeApi *api, RimeSessionId session) {
  char prop[65536] = {};
  if (!api->get_property(session, "_jev_snapshot", prop, sizeof(prop))) return @{};
  NSData *raw = [[NSString stringWithUTF8String:prop] dataUsingEncoding:NSUTF8StringEncoding];
  id value = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSDictionary *state(RimeApi *api, RimeSessionId session, const RimeContext& ctx) {
  const char *raw = api->get_input(session);
  return @{@"page":@(ctx.menu.page_no), @"highlight":@(ctx.menu.highlighted_candidate_index),
           @"caret":@(api->get_caret_pos(session)), @"input":raw ? [NSString stringWithUTF8String:raw] : @""};
}

static NSArray *candidateList(RimeApi *api, RimeSessionId session, int limit) {
  NSMutableArray *rows = [NSMutableArray array];
  RimeCandidateListIterator it = {};
  if (api->candidate_list_begin(session, &it)) {
    while ((int)rows.count < limit && api->candidate_list_next(&it))
      if (it.candidate.text) [rows addObject:[NSString stringWithUTF8String:it.candidate.text]];
    api->candidate_list_end(&it);
  }
  return rows;
}

static void recordResult(RimeApi *api, RimeSessionId session, int limit,
                         NSMutableDictionary *output, NSString *name) {
  output[name] = candidateList(api, session, limit);
  char applied[65536] = {};
  api->get_property(session, "_jev_applied", applied, sizeof(applied));
  output[[name stringByAppendingString:@"_applied"]] = [NSString stringWithUTF8String:applied];
  RIME_STRUCT(RimeContext, ctx);
  if (api->get_context(session, &ctx)) {
    NSMutableDictionary *refresh = [state(api, session, ctx) mutableCopy];
    NSMutableArray *page = [NSMutableArray array];
    for (int i = 0; i < ctx.menu.num_candidates; ++i)
      [page addObject:ctx.menu.candidates[i].text ? [NSString stringWithUTF8String:ctx.menu.candidates[i].text] : @""];
    refresh[@"page_candidates"] = page;
    int highlighted = ctx.menu.highlighted_candidate_index;
    if (highlighted >= 0 && highlighted < (int)page.count) refresh[@"highlighted_text"] = page[highlighted];
    output[[name stringByAppendingString:@"_state"]] = refresh;
    api->free_context(&ctx);
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 3) { std::cerr << "usage: rime_probe USER_DIR SHARED_DIR\n"; return 2; }
    char userDir[PATH_MAX], sharedDir[PATH_MAX];
    if (!realpath(argv[1], userDir) || !realpath(argv[2], sharedDir) || chdir(userDir)) return 2;
    const std::string fw = "/Library/Input Methods/Squirrel.app/Contents/Frameworks/";
    for (const auto* name : {"lua", "octagram", "predict"}) {
      auto path = fw + "rime-plugins/librime-" + name + ".dylib";
      if (!dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL)) { std::cerr << "plugin load failed: " << name << "\n"; return 3; }
    }
    auto api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    traits.user_data_dir = userDir; traits.shared_data_dir = sharedDir;
    traits.app_name = "rime.jev.probe"; traits.min_log_level = 3; traits.log_dir = "";
    const char *modules[] = {"default", "lua", "octagram", "predict", nullptr}; traits.modules = modules;
    api->setup(&traits); api->initialize(&traits);
    std::string line;
    while (std::getline(std::cin, line)) {
      @autoreleasepool {
        NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
        NSError *err = nil;
        NSDictionary *input = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![input isKindOfClass:[NSDictionary class]] || ![input[@"pinyin"] isKindOfClass:[NSString class]]) continue;
        auto s = api->create_session();
        bool ok = api->select_schema(s, "wanxiang");
        api->set_option(s, "ascii_mode", False);
        api->set_property(s, "_jev_epoch", "probe");
        NSString *pinyin = input[@"pinyin"];
        for (unsigned char c : std::string([pinyin UTF8String])) api->process_key(s, c, 0);
        if (input[@"caret"]) api->set_caret_pos(s,[input[@"caret"] unsignedIntegerValue]);
        if ([input[@"confirm_prefix"] boolValue]) api->select_candidate(s,0);
        NSArray *navigation = input[@"navigation_keys"] ?: @[];
        for (NSUInteger i=0;i<std::min((NSUInteger)8,navigation.count);i++)
          api->process_key(s,[navigation[i] intValue],0);
        RIME_STRUCT(RimeContext, ctx);
        NSString *preedit = @"";
        NSDictionary *initialSnapshot = @{}, *before = @{}, *after = @{};
        if (api->get_context(s, &ctx)) {
          initialSnapshot = snapshot(api, s);
          before = state(api, s, ctx);
          if (ctx.composition.preedit) preedit = [NSString stringWithUTF8String:ctx.composition.preedit];
          api->free_context(&ctx);
        }
        NSDictionary *sampledSnapshot = initialSnapshot;
        NSMutableArray *sampled = [NSMutableArray array], *batches = [NSMutableArray array];
        int sampledRaw = 0;
        bool sampling = [input[@"sample_candidates"] boolValue];
        if (sampling) {
          while (sampledRaw < 64 && [sampledSnapshot[@"candidates"] count] < 24) {
            RimeCandidateListIterator batch = {};
            if (!api->candidate_list_from_index(s, &batch, sampledRaw)) break;
            int start = sampledRaw;
            while (sampledRaw - start < 8 && sampledRaw < 64 &&
                   [sampledSnapshot[@"candidates"] count] < 24 && api->candidate_list_next(&batch)) {
              ++sampledRaw;
              if (batch.candidate.text) [sampled addObject:[NSString stringWithUTF8String:batch.candidate.text]];
              sampledSnapshot = snapshot(api, s);
            }
            api->candidate_list_end(&batch);
            [batches addObject:@{@"start":@(start), @"raw_count":@(sampledRaw-start),
                                @"snapshot_count":@([sampledSnapshot[@"candidates"] count])}];
            if (sampledRaw - start < 8) break;
          }
        }
        RIME_STRUCT(RimeContext, sampledContext);
        if (api->get_context(s, &sampledContext)) {
          after = state(api, s, sampledContext);
          api->free_context(&sampledContext);
        }
        int limit = input[@"limit"] ? [input[@"limit"] intValue] : 24;
        limit = std::max(1, std::min(128, limit));
        NSArray *candidates = candidateList(api, s, limit);
        NSDictionary *fullSnapshot = snapshot(api, s);
        int scoreLimit = input[@"score_limit"] ? [input[@"score_limit"] intValue] : 8;
        scoreLimit = std::max(1, std::min(24, scoreLimit));
        NSMutableDictionary *output = [@{@"id":input[@"id"] ?: @"", @"schema_ok":@(ok), @"pinyin":pinyin,
          @"preedit":preedit, @"candidates":candidates, @"snapshot":fullSnapshot, @"score_limit":@(scoreLimit),
          @"snapshot_before_iteration":initialSnapshot, @"sampled_snapshot":sampledSnapshot,
          @"sampling_before":before, @"sampling_after":after, @"sampled_candidates":sampled,
          @"sample_batches":batches, @"sample_raw_count":@(sampledRaw)} mutableCopy];
        NSString *provider = input[@"provider"] ?: @"local";
        output[@"provider"] = provider;
        if (input[@"promote_index"]) {
          NSArray *rows = (sampling ? sampledSnapshot : fullSnapshot)[@"candidates"];
          NSUInteger n = std::min((NSUInteger)scoreLimit, rows.count), idx = [input[@"promote_index"] unsignedIntegerValue];
          output[@"promotion_count"] = @(n);
          if (idx < n) {
            NSMutableArray *keys=[NSMutableArray array];
            for (NSUInteger i=0;i<n;i++) [keys addObject:rows[i][@"key"]];
            output[@"target"] = rows[idx];
            NSString *targetKey = [input[@"invalid_target"] boolValue] ? @"missing-candidate" : rows[idx][@"key"];
            std::string wire="probe|"+hex([pinyin UTF8String])+"|"+[targetKey UTF8String]+"|"+std::to_string(n)+"|"+hex([[keys componentsJoinedByString:@"\n"] UTF8String])+"|"+[provider UTF8String];
            if ([input[@"stale"] boolValue]) wire="old-"+wire;
            api->set_property(s,"_jev_result",wire.c_str());
            recordResult(api, s, limit, output, @"reordered");
            output[@"applied"] = output[@"reordered_applied"];
            if ([input[@"repeat_result"] boolValue]) {
              api->set_property(s, "_jev_result", wire.c_str());
              recordResult(api, s, limit, output, @"repeated");
            }
            if ([input[@"clear_after"] boolValue] || [input[@"stale_after"] boolValue]) {
              std::string replacement = [input[@"stale_after"] boolValue] ? "old-" + wire : "";
              api->set_property(s, "_jev_result", replacement.c_str());
              recordResult(api, s, limit, output, @"restored");
              if ([input[@"reapply_after_clear"] boolValue]) {
                api->set_property(s, "_jev_result", wire.c_str());
                recordResult(api, s, limit, output, @"reapplied");
              }
            }
          }
        }
        if (input[@"commit_index"] || input[@"commit_key"]) {
          if (input[@"commit_key"]) {
            int key = [input[@"commit_key"] intValue];
            output[@"commit_key"] = @(key);
            output[@"commit_accepted"] = @(api->process_key(s, key, 0));
          } else {
            output[@"commit_index"] = input[@"commit_index"];
            output[@"commit_accepted"] = @(api->select_candidate(s, [input[@"commit_index"] unsignedIntegerValue]));
          }
          RIME_STRUCT(RimeCommit, commit);
          if(api->get_commit(s,&commit)) { output[@"committed"] = commit.text ? [NSString stringWithUTF8String:commit.text] : @""; api->free_commit(&commit); }
        }
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
        std::cout.write((const char *)encoded.bytes, encoded.length); std::cout << '\n' << std::flush;
        api->destroy_session(s);
      }
    }
    api->finalize();
  }
}
