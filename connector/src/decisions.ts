export type Question={id:string;header:string;question:string;options:{label:string;description:string}[];isSecret?:boolean};
const headers=new Set(["Data","Security","Commitment","Scope"]);

export function importantDecision(params:any):{questions:Question[]}|null {
  if(!Array.isArray(params?.questions) || params.questions.length!==1)return null;
  const q=params.questions[0];
  if(!q || !headers.has(q.header) || q.isSecret===true || typeof q.id!=="string" || !/^[a-zA-Z0-9_-]{1,80}$/.test(q.id) ||
    typeof q.question!=="string" || !q.question.trim() || q.question.length>600 || !Array.isArray(q.options) || q.options.length!==2 ||
    !q.options.every((option:any,index:number)=>option?.label===["Approve","Deny"][index] && typeof option.description==="string" && option.description.trim().length>0 && option.description.length<=200))return null;
  return {questions:[{id:q.id,header:q.header,question:q.question,options:q.options}]};
}

export function autonomousAnswer(params:any):{answers:Record<string,{answers:string[]}>} {
  const questions=Array.isArray(params?.questions)?params.questions.slice(0,5):[];
  return {answers:Object.fromEntries(questions.filter((q:any)=>typeof q?.id==="string" && /^[a-zA-Z0-9_-]{1,80}$/.test(q.id)).map((q:any)=>[q.id,{answers:["Resolve routine implementation choices autonomously using existing conventions and the safest reversible in-scope option. Fix technical failures and verify your work. Do not infer approval for destructive actions, scope expansion, permission changes, external commitments or deployment. For an indispensable high-impact decision, submit one concrete Approve/Deny proposal using the documented Decision header."]}]))};
}

export const decisionInstructions="Resolve routine choices, missing packages, test failures and review findings autonomously. Ask a human only for an indispensable decision involving irreversible data changes, security/privacy boundaries, external financial/contractual commitments, or material task-scope changes with no safe reversible default. Use request_user_input with exactly one question: header must be Data, Security, Commitment, or Scope (all fit the input tool's short-header limit); describe the concrete proposed action and consequences; provide exactly two options labeled Approve and Deny with useful descriptions. If interactive input is unavailable, return outcome=blocked with the same question object in the structured decision field and blocker.category=missing_context; the connector will persist and deliver the decision. Use decision=null for ordinary results. Denial means do not perform the proposed action; continue safely if possible. Approval changes task intent only and never expands sandbox, network, credential, publishing or deployment authority. Never ask the human to debug a technical failure. If required evidence is missing, describe the missing prerequisite rather than proposing that approval can replace it.";
