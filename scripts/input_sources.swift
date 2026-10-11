import Carbon
import Foundation
let list=TISCreateInputSourceList(nil,true).takeRetainedValue() as! [TISInputSource]
func string(_ s:TISInputSource,_ key:CFString)->String? {
 guard let p=TISGetInputSourceProperty(s,key) else{return nil}
 return unsafeBitCast(p,to:CFString.self) as String
}
func flag(_ s:TISInputSource,_ key:CFString)->Bool {
 guard let p=TISGetInputSourceProperty(s,key) else{return false}
 return CFBooleanGetValue(unsafeBitCast(p,to:CFBoolean.self))
}
let rows=list.compactMap { s -> [String:Any]? in
 guard let id=string(s,kTISPropertyInputSourceID), id.contains("Squirrel") || id.contains("RimeJev") || flag(s,kTISPropertyInputSourceIsSelected) else{return nil}
 return ["id":id,"name":string(s,kTISPropertyLocalizedName) ?? "", "enabled":flag(s,kTISPropertyInputSourceIsEnabled),"selected":flag(s,kTISPropertyInputSourceIsSelected)]
}
let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
