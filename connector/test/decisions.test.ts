import test from "node:test";
import assert from "node:assert/strict";
import * as decisions from "../src/decisions.ts";

test("only explicit high-impact binary proposals qualify for a human decision",()=>{
  const question={id:"retention",header:"Data",question:"Approve removing archived customer records? This permanently removes retained history.",options:[{label:"Approve",description:"Remove the specified records"},{label:"Deny",description:"Keep existing records and continue without removal"}]};
  assert.equal(decisions.importantDecision({questions:[question]})?.questions[0].id,"retention");
  for(const questions of [[{...question,header:"Framework"}],[question,question],[{...question,isSecret:true}],[{...question,options:[{label:"Approve",description:""}]}]])
    assert.equal(decisions.importantDecision({questions}),null);
});

test("routine questions receive autonomous guidance instead of implicit approval",()=>{
  const result=decisions.autonomousAnswer({questions:[{id:"framework",question:"Which framework?"}]});
  assert.match(result.answers.framework.answers[0],/existing conventions|reversible/);
  assert.doesNotMatch(result.answers.framework.answers[0],/^Approve$/);
});
